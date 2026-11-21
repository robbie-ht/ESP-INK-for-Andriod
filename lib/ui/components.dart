import 'package:flutter/material.dart';

import '../app/models.dart';

const mutedText = Color(0xFF647084);
const sectionFill = Color(0xFFEEF2F8);

class Brand extends StatelessWidget {
  const Brand({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 39,
        height: 39,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(
          Icons.filter_none_rounded,
          color: Color(0xFF1967D2),
          size: 23,
        ),
      ),
      const SizedBox(width: 11),
      const Text(
        'MoInk',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -.8,
        ),
      ),
      if (!compact) ...[
        const SizedBox(width: 8),
        const Text('墨印', style: TextStyle(fontSize: 14, color: mutedText)),
        const SizedBox(width: 14),
        const InkDots(size: 6, spacing: 4),
      ],
    ],
  );
}

class InkDots extends StatelessWidget {
  const InkDots({super.key, this.size = 12, this.spacing = 7});
  final double size, spacing;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [inkBlack, Colors.white, inkYellow, inkRed]
        .map(
          (c) => Padding(
            padding: EdgeInsets.only(right: spacing),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: c == Colors.white
                    ? Border.all(color: const Color(0xFFD3D9E2))
                    : null,
              ),
            ),
          ),
        )
        .toList(),
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.color = Colors.white,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(28),
      side: const BorderSide(color: Color(0xFFE7EBF2)),
    ),
    child: Padding(padding: padding, child: child),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: const TextStyle(fontSize: 12, color: mutedText),
              ),
            ],
          ],
        ),
      ),
      ?trailing,
    ],
  );
}

class TonalLabel extends StatelessWidget {
  const TonalLabel(
    this.text, {
    super.key,
    this.icon,
    this.color = const Color(0xFFEAF1FD),
    this.foreground = const Color(0xFF255DB3),
  });
  final String text;
  final IconData? icon;
  final Color color, foreground;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 5),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: foreground,
          ),
        ),
      ],
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = '确认',
  bool danger = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 54),
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(23),
          decoration: const BoxDecoration(
            color: Color(0xFFE9F0FC),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 37, color: const Color(0xFF3876D0)),
        ),
        const SizedBox(height: 23),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 9),
        Text(
          description,
          style: const TextStyle(color: mutedText),
          textAlign: TextAlign.center,
        ),
        if (action != null) ...[const SizedBox(height: 23), action!],
      ],
    ),
  );
}
