import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/theme.dart';

/// Анімована кнопка з ефектами натискання та hover
class AnimatedButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final double? elevation;
  final bool isPrimary;

  const AnimatedButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.backgroundColor,
    this.foregroundColor,
    this.padding,
    this.borderRadius,
    this.elevation,
    this.isPrimary = false,
  });

  @override
  State<AnimatedButton> createState() => _AnimatedButtonState();
}

class _AnimatedButtonState extends State<AnimatedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _onTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    _controller.reverse();
    widget.onPressed?.call();
  }

  void _onTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = widget.backgroundColor ?? 
        (widget.isPrimary ? AppTheme.primaryOrange : AppTheme.darkContainer);
    final foregroundColor = widget.foregroundColor ?? AppTheme.textPrimary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final scale = 1.0 - (_controller.value * 0.05);
            final elevation = (widget.elevation ?? 6) * (1.0 - _controller.value * 0.3);
            
            return Transform.scale(
              scale: scale,
              child: Container(
                padding: widget.padding ?? 
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  gradient: widget.isPrimary ? AppTheme.primaryGradient : null,
                  color: widget.isPrimary ? null : backgroundColor,
                  borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: backgroundColor.withOpacity(0.3),
                      blurRadius: elevation,
                      offset: Offset(0, elevation / 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(
                        widget.icon,
                        color: foregroundColor,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                    ],
                    DefaultTextStyle(
                      style: TextStyle(
                        color: foregroundColor,
                        fontWeight: FontWeight.w600,
                      ),
                      child: widget.child,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ).animate()
      .fadeIn(duration: 300.ms)
      .slideY(begin: 0.2, end: 0, duration: 300.ms, curve: Curves.easeOutBack);
  }
}

/// Анімована іконка кнопка
class AnimatedIconButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final Color? color;
  final double size;
  final String? tooltip;
  final bool isActive;

  const AnimatedIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.color,
    this.size = 24,
    this.tooltip,
    this.isActive = false,
  });

  @override
  State<AnimatedIconButton> createState() => _AnimatedIconButtonState();
}

class _AnimatedIconButtonState extends State<AnimatedIconButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? 
        (widget.isActive ? AppTheme.primaryOrange : AppTheme.textSecondary);

    return Tooltip(
      message: widget.tooltip ?? '',
      child: GestureDetector(
        onTapDown: (_) {
          setState(() => _isPressed = true);
          _controller.forward();
        },
        onTapUp: (_) {
          setState(() => _isPressed = false);
          _controller.reverse();
          widget.onPressed?.call();
        },
        onTapCancel: () {
          setState(() => _isPressed = false);
          _controller.reverse();
        },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final scale = 1.0 - (_controller.value * 0.1);
            
            return Transform.scale(
              scale: scale,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: widget.isActive 
                      ? AppTheme.primaryOrange.withOpacity(0.2)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  widget.icon,
                  color: color,
                  size: widget.size,
                ),
              ),
            );
          },
        ),
      ),
    ).animate()
      .fadeIn(duration: 200.ms)
      .scale(begin: const Offset(0.8, 0.8), duration: 200.ms);
  }
}

/// Floating Action Button з пульсацією
class PulsatingFAB extends StatefulWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String? tooltip;
  final bool isActive;

  const PulsatingFAB({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.isActive = false,
  });

  @override
  State<PulsatingFAB> createState() => _PulsatingFABState();
}

class _PulsatingFABState extends State<PulsatingFAB>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    
    if (widget.isActive) {
      _pulseController.repeat();
    }
  }

  @override
  void didUpdateWidget(PulsatingFAB oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        _pulseController.repeat();
      } else {
        _pulseController.stop();
        _pulseController.reset();
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = 1.0 + (_pulseController.value * 0.1);
        
        return Transform.scale(
          scale: scale,
          child: FloatingActionButton(
            onPressed: widget.onPressed,
            tooltip: widget.tooltip,
            backgroundColor: AppTheme.primaryOrange,
            foregroundColor: AppTheme.textPrimary,
            elevation: 8,
            child: Icon(widget.icon, size: 28),
          ),
        );
      },
    ).animate()
      .fadeIn(duration: 300.ms)
      .slideY(begin: 1, duration: 400.ms, curve: Curves.elasticOut);
  }
}

/// Анімована картка з hover ефектом
class AnimatedCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const AnimatedCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.margin,
  });

  @override
  State<AnimatedCard> createState() => _AnimatedCardState();
}

class _AnimatedCardState extends State<AnimatedCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: widget.margin ?? const EdgeInsets.all(8),
          padding: widget.padding ?? const EdgeInsets.all(16),
          transform: Matrix4.identity()
            ..scale(_isHovered ? 1.02 : 1.0),
          decoration: BoxDecoration(
            color: AppTheme.darkSurface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_isHovered ? 0.4 : 0.2),
                blurRadius: _isHovered ? 12 : 8,
                offset: Offset(0, _isHovered ? 6 : 4),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    ).animate()
      .fadeIn(duration: 400.ms)
      .slideY(begin: 0.3, duration: 400.ms, curve: Curves.easeOutBack);
  }
}