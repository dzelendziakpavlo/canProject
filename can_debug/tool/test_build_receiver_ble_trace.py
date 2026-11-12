import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

import build_receiver_ble_trace as build


class BuildGuardTest(unittest.TestCase):
    def elf(self):
        data = bytearray(200)
        data[:6] = b'\x7fELF\x01\x01'
        struct.pack_into('<I', data, 32, 52)
        struct.pack_into('<HH', data, 46, 40, 2)
        struct.pack_into('<10I', data, 52, 0, 1, 2, 0x400d0000, 160, 4, 0, 0, 4, 0)
        struct.pack_into('<10I', data, 92, 0, 1, 0, 0, 164, 4, 0, 0, 4, 0)
        struct.pack_into('<I', data, 160, 0x400d1234)
        return data

    def test_linked_literal_is_read_at_virtual_address(self):
        data = self.elf()
        self.assertEqual(build.elf_word(data, 0x400d0000), 0x400d1234)
        with self.assertRaises(ValueError):
            build.elf_word(data, 0x400d0010)

    def test_inspection_metadata_changes_cannot_hide_allocated_byte_changes(self):
        original = self.elf()
        metadata = bytearray(original); metadata[164] = 42
        self.assertEqual(build.allocated_elf_sections(original), build.allocated_elf_sections(metadata))
        changed_code = bytearray(original); changed_code[160] ^= 1
        self.assertNotEqual(build.allocated_elf_sections(original), build.allocated_elf_sections(changed_code))

    def test_unknown_private_abi_stops_before_compiler_or_stack_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp)
            lib = fake / 'Arduino15/packages/esp32/tools/esp32-libs/3.3.10/lib/libbt.a'
            lib.parent.mkdir(parents=True); lib.write_bytes(b'not the audited SDK')
            with mock.patch.dict(os.environ, LOCALAPPDATA=tmp), \
                 mock.patch.object(sys, 'argv', ['build', '--btc-copy', '--build', str(fake/'output')]), \
                 mock.patch.object(build.subprocess, 'run') as compiler:
                with self.assertRaisesRegex(RuntimeError, 'STOP: installed libbt.a differs'):
                    build.main()
                compiler.assert_not_called()


if __name__ == '__main__':
    unittest.main()
