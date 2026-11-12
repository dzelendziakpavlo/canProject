"""Compile-only, pinned ESP32 BLE diagnostics. Never opens a port or uploads."""
import argparse
import hashlib
import json
import os
import re
import struct
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FQBN = ('esp32:esp32:esp32:CPUFreq=240,FlashFreq=80,FlashMode=qio,FlashSize=4M,'
        'PartitionScheme=default,DebugLevel=none,PSRAM=disabled,LoopCore=1,EventsCore=1')


def elf_word(data, address):
    """Read a linked little-endian Xtensa ELF32 literal without executing it."""
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('Expected little-endian ELF32')
    offset = struct.unpack_from('<I', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 46)
    for i in range(count):
        section = struct.unpack_from('<10I', data, offset + i * size)
        if section[1] != 8 and section[3] <= address and address + 4 <= section[3] + section[5]:
            return struct.unpack_from('<I', data, section[4] + address - section[3])[0]
    raise ValueError('Literal address not backed by an ELF section: ' + hex(address))


def allocated_elf_sections(data):
    offset = struct.unpack_from('<I', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 46)
    result = []
    for i in range(count):
        s = struct.unpack_from('<10I', data, offset + i * size)
        if s[2] & 2 and s[1] != 8 and s[5]:
            result.append((s[3], data[s[4]:s[4]+s[5]]))
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', default=r'D:\ArduinoIDE\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe')
    parser.add_argument('--config', default=str(Path.home() / '.arduinoIDE/arduino-cli.yaml'))
    parser.add_argument('--build', type=Path)
    parser.add_argument('--btc-copy', action='store_true', help='Add the pinned post-deep-copy probe; builds into a separate directory')
    parser.add_argument('--btc-handler', action='store_true', help='Also snapshot BTC handler entry; implies --btc-copy')
    args = parser.parse_args()
    if args.btc_handler:
        args.btc_copy = True
    default_build = 'receiver_btc_handler_trace' if args.btc_handler else ('receiver_btc_trace' if args.btc_copy else 'receiver_ble_trace')
    args.build = (args.build or ROOT / 'can_debug/build' / default_build).resolve()
    args.build.mkdir(parents=True, exist_ok=True)
    sources = list((ROOT / 'arduino/receiver_ble').glob('*'))
    def source_hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()}
    hashes = source_hashes()
    installed = Path(os.environ['LOCALAPPDATA']) / 'Arduino15/packages/esp32'
    abi_manifest = json.loads((Path(__file__).with_name('btc_copy_abi.json')).read_text()) if args.btc_copy else None
    if args.btc_copy:
        lib = installed / 'tools/esp32-libs/3.3.10/lib/libbt.a'
        if hashlib.sha256(lib.read_bytes()).hexdigest() != abi_manifest['installedLibbtSha256']:
            raise RuntimeError('STOP: installed libbt.a differs from the audited private ABI; do not apply this probe')
    if args.btc_handler:
        for name, digest in abi_manifest['handlerNativeCas']['headers'].items():
            path = installed / 'tools/esp32-libs/3.3.10' / name
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise RuntimeError('STOP: native CAS header differs from the audited nonblocking implementation')
    manifest_path = args.build / 'build_manifest.json'
    manifest_path.write_text(json.dumps({'uploaded': False, 'verification': 'building', 'sourceHashes': hashes}, indent=2), encoding='utf-8')
    cpp_flags = '-DRECEIVER_BLE_TRACE=1 -DRECEIVER_TRACE_LINK_WRAP=1'
    link_flags = '-Wl,--wrap=esp_ble_gatts_send_indicate'
    if args.btc_copy:
        cpp_flags += ' -DRECEIVER_BTC_TRACE=1 -DRECEIVER_BTC_LINK_WRAP=1'
        link_flags += ' -Wl,--wrap=btc_gatts_arg_deep_copy'
    if args.btc_handler:
        cpp_flags += ' -DRECEIVER_BTC_HANDLER_TRACE=1 -DRECEIVER_BTC_HANDLER_LINK_WRAP=1'
        link_flags += ' -Wl,--wrap=btc_gatts_call_handler -Wl,--wrap=btc_gatts_arg_deep_free'
    command = [args.cli, 'compile', '--config-file', args.config, '--fqbn', FQBN,
               '--build-path', str(args.build), '--jobs', '4',
               '--build-property', 'compiler.cpp.extra_flags=' + cpp_flags,
               '--build-property', 'compiler.c.elf.extra_flags=' + link_flags,
               str(ROOT / 'arduino/receiver_ble')]
    log = args.build / 'compile.log'
    with log.open('wb') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    print(log.read_text(encoding='utf-8', errors='replace'))
    result.check_returncode()
    if source_hashes() != hashes:
        raise RuntimeError('Firmware sources changed during compilation; rebuild before uploading')
    # Verify the actual linked code, not just the requested build flags.
    tools = Path(os.environ['LOCALAPPDATA']) / 'Arduino15/packages/esp32/tools/esp-x32/2601/bin'
    elf = args.build / 'receiver_ble.ino.elf'
    inspection = args.build / 'link-inspection.elf'
    # Mixed SDK/sketch .xt.prop metadata can make objdump display code as data.
    # Strip ONLY inspection metadata in a COPY; validate every allocated byte.
    # The actual firmware ELF and flash BIN are never altered by this step.
    subprocess.run([str(tools / 'xtensa-esp-elf-objcopy.exe'), '--remove-section=.xt.prop',
                    '--remove-section=.xt.lit', str(elf), str(inspection)], check=True)
    if allocated_elf_sections(elf.read_bytes()) != allocated_elf_sections(inspection.read_bytes()):
        raise RuntimeError('Inspection copy changed allocated bytes; link verification aborted')
    disassembly = subprocess.check_output([str(tools / 'xtensa-esp-elf-objdump.exe'), '-d', '-C', str(inspection)], text=True)
    def body(name):
        start = disassembly.index('<' + name + '>:')
        return disassembly[start:disassembly.find('\n\n', start)]
    notify = body('BLECharacteristic::notify(bool)')
    wrapper = body('__wrap_esp_ble_gatts_send_indicate')
    if '<__wrap_esp_ble_gatts_send_indicate>' not in notify or '<esp_ble_gatts_send_indicate>' not in wrapper:
        raise RuntimeError('Linked notify -> wrapper -> real API chain was not verified')
    link_evidence = notify + '\n\n' + wrapper
    btc_pointer_verified = False
    handler_pointer_verified = False
    free_pointer_verified = False
    native_cas_verified = False
    if args.btc_copy:
        btc_wrapper = body('__wrap_btc_gatts_arg_deep_copy')
        api = body('esp_ble_gatts_send_indicate')
        symbols = subprocess.check_output([str(tools / 'xtensa-esp-elf-nm.exe'), str(elf)], text=True)
        address = int(re.search(r'^([0-9a-fA-F]+)\s+\w\s+__wrap_btc_gatts_arg_deep_copy$', symbols, re.M)[1], 16)
        literals = [int(x, 16) for x in re.findall(r'\bl32r\s+a\d+,\s*([0-9a-fA-F]+)', api)]
        btc_pointer_verified = any(elf_word(elf.read_bytes(), x) == address for x in literals)
        if not btc_pointer_verified or '<btc_gatts_arg_deep_copy>' not in btc_wrapper:
            raise RuntimeError('STOP: send API callback pointer -> wrapper -> original deep copy was not verified')
        link_evidence += '\n\n' + api + '\n\n' + btc_wrapper + '\nCallback pointer verified at ' + hex(address)
    if args.btc_handler:
        def symbol(name):
            return int(re.search(r'^([0-9a-fA-F]+)\s+\w\s+' + re.escape(name) + r'$', symbols, re.M)[1], 16)
        handler_wrapper = body('__wrap_btc_gatts_call_handler')
        free_wrapper = body('__wrap_btc_gatts_arg_deep_free')
        handler_pointer_verified = (elf_word(elf.read_bytes(), symbol('profile_tab') + abi_manifest['handlerProfileTable']['gattsCallOffset']) == symbol('__wrap_btc_gatts_call_handler'))
        free_pointer_verified = any(elf_word(elf.read_bytes(), x) == symbol('__wrap_btc_gatts_arg_deep_free') for x in literals)
        if (not handler_pointer_verified or not free_pointer_verified or
                '<btc_gatts_call_handler>' not in handler_wrapper or '<btc_gatts_arg_deep_free>' not in free_wrapper):
            raise RuntimeError('STOP: handler table/free callback/original calls were not verified')
        slots_address = symbol('_ZN12_GLOBAL__N_15slotsE')
        critical = handler_wrapper + '\n' + free_wrapper
        for name in re.findall(r'^[0-9a-fA-F]+ <(.+)>:', disassembly, re.M):
            if (name.startswith('(anonymous namespace)::') or name.startswith('_ZN12_GLOBAL')) and any(
                    part in name for part in ('handlerSnapshot', 'cancelBeforeFree', 'claim(', 'adjust(', 'increment(', 'load(', 'store(')):
                critical += '\n' + body(name)
        forbidden = ('<malloc', '<calloc', '<mbedtls_', 'HardwareSerial::', 'Print::', '<xQueue', 'Semaphore',
                     'PortEnterCritical', 'vTaskDelay', '<__atomic_')
        native_cas_verified = (0x3ffae000 <= slots_address < 0x40000000 and 's32c1i' in critical and
                               not any(s in critical for s in forbidden) and not re.search(r'\b(rsil|waiti)\b', critical))
        if not native_cas_verified:
            raise RuntimeError('STOP: native CAS/internal DRAM verification failed')
        link_evidence += '\n\n' + critical + '\nHandler table, lifetime guard and nonblocking native-CAS hot path verified.'
    (args.build / 'link_check.txt').write_text(link_evidence, encoding='utf-8')
    sdk_files = [installed / 'hardware/esp32/3.3.10' / p for p in (
        'libraries/BLE/src/BLECharacteristic.cpp', 'libraries/BLE/src/BLEValue.cpp',
        'cores/esp32/WString.cpp', 'libraries/BLE/library.properties')]
    sdk_files += [installed / 'tools/esp32-libs/3.3.10' / p for p in ('versions.txt', 'lib/libbt.a', 'sdkconfig')]
    if args.btc_handler:
        sdk_files += [installed / 'tools/esp32-libs/3.3.10' / p for p in abi_manifest['handlerNativeCas']['headers']]
    binary = args.build / 'receiver_ble.ino.bin'
    manifest = {'uploaded': False, 'verification': 'compile_and_link_only', 'core': '3.3.10',
                'idf': '5.5.4', 'fqbn': FQBN, 'command': command, 'sourceHashes': hashes,
                'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'sdkHashes': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sdk_files},
                'linkedNotifyWrapperRealApiVerified': True,
                'btcCopyProbe': args.btc_copy, 'btcCallbackPointerAndOriginalVerified': btc_pointer_verified,
                'btcHandlerProbe': args.btc_handler, 'btcHandlerTableAndOriginalVerified': handler_pointer_verified,
                'btcFailureFreeCallbackAndOriginalVerified': free_pointer_verified,
                'handlerNativeCasAndDramVerified': native_cas_verified,
                'btcPrivateAbiAudit': abi_manifest}
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print('Verified compile + actual wrapper linkage:', binary)


if __name__ == '__main__':
    main()
