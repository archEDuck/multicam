class Sam2Point {
  final double x;
  final double y;
  final bool isPositive;

  const Sam2Point({required this.x, required this.y, required this.isPositive});

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'x': x, 'y': y, 'label': isPositive ? 1 : 0};
  }
}
