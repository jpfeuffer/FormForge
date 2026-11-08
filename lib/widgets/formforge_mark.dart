import 'package:flutter/material.dart';

class FormForgeMark extends StatelessWidget {
  const FormForgeMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'FormForge',
    image: true,
    child: ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .24),
        child: SizedBox.square(
          dimension: size,
          child: const ColoredBox(
            color: Color(0xFF16213F),
            child: CustomPaint(painter: _FormForgeMarkPainter()),
          ),
        ),
      ),
    ),
  );
}

class _FormForgeMarkPainter extends CustomPainter {
  const _FormForgeMarkPainter();

  static const _white = Color(0xFFFFFFFF);
  static const _lime = Color(0xFFD8FF3F);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    _polygon(canvas, const [
      Offset(17, 18),
      Offset(57, 18),
      Offset(50, 28),
      Offset(31, 28),
      Offset(27, 38),
      Offset(44, 38),
      Offset(39, 48),
      Offset(23, 48),
      Offset(16, 70),
      Offset(4, 70),
    ], _white);
    _polygon(canvas, const [
      Offset(58, 32),
      Offset(96, 32),
      Offset(89, 42),
      Offset(71, 42),
      Offset(68, 52),
      Offset(85, 52),
      Offset(80, 62),
      Offset(64, 62),
      Offset(57, 82),
      Offset(45, 82),
    ], _lime);
    canvas.restore();
  }

  void _polygon(Canvas canvas, List<Offset> points, Color color) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _FormForgeMarkPainter oldDelegate) => false;
}
