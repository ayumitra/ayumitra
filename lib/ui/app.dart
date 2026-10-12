import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/local_file_picker.dart';
import '../app_controller.dart';
import '../domain/records.dart';
import '../domain/retrieval.dart';
import 'source_screen.dart';

const ink = Color(0xff203f38);
const canvas = Color(0xfff7f8f2);

class AyumitraApp extends StatelessWidget {
  const AyumitraApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ayumitra',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff477c68),
        surface: canvas,
        brightness: Brightness.light,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    builder: (context, child) => PrivacyCover(
      child: controller.isPreview
          ? Column(
              children: [
                Material(
                  color: const Color(0xffe3efe8),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        'UX preview · Synthetic reports · Sample responses · Nothing saved',
                        style: Theme.of(context).textTheme.labelMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                Expanded(child: child!),
              ],
            )
          : child!,
    ),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.loaded) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: controller.failure == null
                    ? const CircularProgressIndicator()
                    : Text(controller.failure!, textAlign: TextAlign.center),
              ),
            ),
          );
        }
        if (controller.profile == null) {
          return Onboarding(controller: controller);
        }
        return CompanionScreen(controller: controller);
      },
    ),
  );
}

class PrivacyCover extends StatefulWidget {
  const PrivacyCover({super.key, required this.child});
  final Widget child;
  @override
  State<PrivacyCover> createState() => _PrivacyCoverState();
}

class _PrivacyCoverState extends State<PrivacyCover>
    with WidgetsBindingObserver {
  bool hidden = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() => hidden = state != AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (hidden)
        const Positioned.fill(
          child: ColoredBox(
            color: canvas,
            child: Center(
              child: Icon(
                Icons.health_and_safety_outlined,
                size: 64,
                color: ink,
              ),
            ),
          ),
        ),
    ],
  );
}

class Onboarding extends StatefulWidget {
  const Onboarding({super.key, required this.controller});
  final AppController controller;
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      age = TextEditingController(),
      history = TextEditingController();
  bool child = true;
  @override
  void dispose() {
    name.dispose();
    age.dispose();
    history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.spa_outlined, color: ink, size: 44),
                  const SizedBox(height: 28),
                  const Text(
                    'AYUMITRA',
                    style: TextStyle(
                      letterSpacing: 3,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Your health story.\nAlways with you.',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'A private companion for your reports, questions, and lifelong history.',
                    style: TextStyle(fontSize: 16, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('For my child')),
                      ButtonSegment(value: false, label: Text('For me')),
                    ],
                    selected: {child},
                    onSelectionChanged: (v) => setState(() => child = v.first),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: child ? 'Child’s name' : 'Your name',
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Enter a name.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: age,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Age in years',
                      helperText: 'Age is recorded with today’s date.',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 0 || n > 125
                          ? 'Enter an age from 0 to 125.'
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: history,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'Previous history (optional)',
                      hintText:
                          'Conditions, allergies, medicines, or anything you want me to remember.',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.lock_outline, size: 18, color: ink),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.controller.isPreview
                              ? 'Use invented details. This preview uses synthetic reports and sample responses, and clears on reload.'
                              : 'Your records and AI stay on this phone. The assistant can search public web information; it never uploads your reports.',
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: widget.controller.busy
                          ? null
                          : () async {
                              if (!form.currentState!.validate()) return;
                              await widget.controller.createProfile(
                                name.text,
                                int.parse(age.text),
                                history.text,
                                child,
                              );
                            },
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Start my history'),
                      ),
                    ),
                  ),
                  if (widget.controller.failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(widget.controller.failure!),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> {
  final input = TextEditingController();
  int section = 0;
  String? category;
  String? selectedAge;
  AppController get c => widget.controller;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> attach() async {
    if (c.busy) return;
    if (c.isPreview) {
      await c.attachReport();
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Choose a file'),
              subtitle: const Text('PDF, PNG, JPG or text, up to 30 MB.'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Scan with camera'),
              subtitle: const Text(
                'Fill the frame with the report, avoid glare, hold steady.',
              ),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'camera') {
      await c.capturePhoto();
    } else if (choice == 'file') {
      await c.attachReport();
    }
  }

  void openReport(Report r) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ReportScreen(controller: c, reportId: r.id),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          const Icon(Icons.spa_outlined, color: ink),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ayumitra',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${c.profile!.name}’s companion',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: c.isPreview
              ? 'About this preview'
              : 'Model and search settings',
          onPressed: c.busy
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(controller: c),
                  ),
                ),
          icon: const Icon(Icons.tune),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 15, color: ink),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c.isPreview
                            ? 'Synthetic session · Sample responses'
                            : c.embeddings.available
                            ? 'Private search on-device · EmbeddingGemma 2'
                            : 'Private records on-device · models need setup',
                        style: const TextStyle(fontSize: 12, color: ink),
                      ),
                    ),
                  ],
                ),
              ),
              if (c.busy)
                LinearProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              if (c.busy)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(c.activity, style: const TextStyle(fontSize: 12)),
                ),
              if (c.failure != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    c.failure!,
                    style: const TextStyle(color: Color(0xff7f4f29)),
                  ),
                ),
              Expanded(child: section == 0 ? _conversation() : _timeline()),
              if (section == 0) _composer(),
            ],
          ),
        ),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: section,
      onDestinationSelected: (v) => setState(() => section = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          label: 'Companion',
        ),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
      ],
    ),
  );

  Widget _conversation() {
    if (c.messages.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 32),
          Text(
            'Hello, ${c.profile!.name}.',
            style: const TextStyle(
              fontSize: 30,
              color: ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Keep your story here. Ask a question, add a report, or look back at what changed.',
            style: TextStyle(fontSize: 17, height: 1.6),
          ),
          const SizedBox(height: 28),
          for (final prompt in [
            'Summarize my medical history',
            'Find my blood reports',
            'What is this medicine used for?',
          ])
            Card(
              child: ListTile(
                title: Text(prompt),
                trailing: const Icon(Icons.north_east, size: 18),
                onTap: () {
                  input.text = prompt;
                },
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: c.busy ? null : attach,
            icon: const Icon(Icons.add),
            label: Text(
              c.isPreview ? 'Add a synthetic report' : 'Add the first report',
            ),
          ),
          TextButton(
            onPressed: c.busy
                ? null
                : () => c.importSample(
                    Uint8List.fromList(
                      utf8.encode(
                        'SYNTHETIC EXAMPLE — NOT A REAL PATIENT\nCategory: Laboratory\nReport date: 2026-10-01\n'
                        'Test | Result | Unit | Printed range\nHemoglobin | 11.2 | g/dL | 10.0-14.0\n'
                        'White blood cells | 7.4 | 10^9/L | 4.0-12.0\n',
                      ),
                    ),
                  ),
            child: const Text('Try a synthetic example'),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: c.messages.length,
      itemBuilder: (context, index) {
        final message = c.messages[index];
        return Align(
          alignment: message.isUser
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(18),
            constraints: const BoxConstraints(maxWidth: 680),
            decoration: BoxDecoration(
              color: message.isUser ? const Color(0xffe4eee5) : Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionArea(
                  child: MarkdownBody(
                    data: _linkedMarkdown(message),
                    selectable: false,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(
                          tableColumnWidth: const IntrinsicColumnWidth(),
                          tableCellsPadding: const EdgeInsets.all(10),
                        ),
                    imageBuilder: (_, _, _) => const SizedBox.shrink(),
                    onTapLink: (_, href, _) {
                      final hit = message.hits
                          .where((h) => href == 'source:${h.citation}')
                          .firstOrNull;
                      if (hit != null) _openSource(hit);
                      final web = message.web
                          .where((s) => href == s.url.toString())
                          .firstOrNull;
                      if (web != null) {
                        launchUrl(
                          web.url,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                  ),
                ),
                if (!message.isUser &&
                    (message.hits.isNotEmpty || message.web.isNotEmpty)) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'SOURCES',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  for (final hit in message.hits.take(6))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined, size: 18),
                      title: Text(
                        hit.report.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Page ${hit.line.page} · ${hit.line.text}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openSource(hit),
                    ),
                  for (final source in message.web)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.public, size: 18),
                      title: Text(source.title),
                      subtitle: Text(
                        '${source.url.host} · ${DateFormat.yMMMd().format(source.retrievedAt.toLocal())}',
                      ),
                      onTap: () => launchUrl(
                        source.url,
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _linkedMarkdown(ChatEntry entry) {
    var text = entry.text;
    for (final hit in entry.hits) {
      text = text.replaceAll(
        '[${hit.citation}]',
        '[Page ${hit.line.page}](source:${hit.citation})',
      );
    }
    for (final source in entry.web) {
      text = text.replaceAll(
        '[${source.id}]',
        '[${source.url.host}](${source.url})',
      );
    }
    return text;
  }

  void _openSource(EvidenceHit hit) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          SourceScreen(controller: c, report: hit.report, line: hit.line),
    ),
  );
  Widget _composer() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          tooltip: c.isPreview ? 'Add a synthetic report' : 'Attach a report',
          onPressed: c.busy ? null : attach,
          icon: const Icon(Icons.add_circle_outline),
        ),
        Expanded(
          child: TextField(
            controller: input,
            minLines: 1,
            maxLines: 5,
            enabled: !c.busy,
            decoration: const InputDecoration(hintText: 'Ask Ayumitra…'),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: c.busy ? null : _send,
          style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
          child: const Icon(Icons.arrow_upward, semanticLabel: 'Send message'),
        ),
      ],
    ),
  );
  Future<void> _send() async {
    final question = input.text.trim();
    if (question.isEmpty) return;
    input.clear();
    await c.ask(question);
  }

  Widget _timeline() {
    final categories = c.reports.map((r) => r.type).toSet();
    final reports =
        timelineFor(c.profile!.id, c.data.reports, category: category)
            .where(
              (r) =>
                  selectedAge == null ||
                  ageAtEvent(c.profile!, r.eventDate) == selectedAge,
            )
            .toList();
    final ageGroups = c.reports
        .map((r) => ageAtEvent(c.profile!, r.eventDate))
        .toSet();
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All ages'),
                  selected: selectedAge == null,
                  onSelected: (_) => setState(() => selectedAge = null),
                ),
              ),
              for (final age in ageGroups)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(age),
                    selected: selectedAge == age,
                    onSelected: (_) => setState(() => selectedAge = age),
                  ),
                ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All reports'),
                  selected: category == null,
                  onSelected: (_) => setState(() => category = null),
                ),
              ),
              for (final type in categories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(type),
                    selected: category == type,
                    onSelected: (_) => setState(() => category = type),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: reports.isEmpty
              ? const Center(child: Text('Your reports will appear here.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: reports.length,
                  itemBuilder: (context, index) {
                    final report = reports[index];
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: const Icon(Icons.article_outlined, color: ink),
                        title: Text(
                          report.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${report.eventDate == null ? 'Report date unknown' : DateFormat.yMMMd().format(report.eventDate!)}\n'
                            '${ageAtEvent(c.profile!, report.eventDate)} · ${report.type}\n${statusLabel(report.status)}',
                            style: const TextStyle(height: 1.6),
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => openReport(report),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: c.busy ? null : attach,
            icon: const Icon(Icons.add),
            label: const Text('Add a report'),
          ),
        ),
      ],
    );
  }
}

String statusLabel(ReportStatus status) => switch (status) {
  ReportStatus.saved => 'Saved',
  ReportStatus.processing => 'Reading locally',
  ReportStatus.needsReview => 'Needs review',
  ReportStatus.ready => 'Ready to review',
  ReportStatus.failed => 'Retry needed',
};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final keyInput = TextEditingController();
  String family = 'gemma4';
  @override
  void dispose() {
    keyInput.dispose();
    super.dispose();
  }

  Future<void> pickModel(bool embedding) async {
    if (widget.controller.isPreview) return;
    final result = await pickLocalFile(['litertlm']);
    if (result != null) {
      await widget.controller.installModel(
        result,
        embedding: embedding,
        family: family,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (c.isPreview) {
        return Scaffold(
          appBar: AppBar(title: const Text('About this preview')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Try the experience',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                'This preview uses synthetic records and sample responses. It keeps the session in memory and clears it on reload. Local model setup, camera capture, and live public search are tested in the mobile app.',
              ),
              const SizedBox(height: 24),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('Open-source licenses'),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Ayumitra',
                ),
              ),
            ],
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Your companion’s setup')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'All AI runs here',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose model files already stored on your phone. There is no remote AI fallback.',
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Local assistant',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      c.intelligence.available
                          ? 'Model configured on-device'
                          : 'Not configured',
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: family,
                      decoration: const InputDecoration(
                        labelText: 'Model family',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'gemma4',
                          child: Text('Gemma 4'),
                        ),
                        DropdownMenuItem(
                          value: 'gemmaIt',
                          child: Text('Gemma 3 / 3n'),
                        ),
                        DropdownMenuItem(value: 'qwen3', child: Text('Qwen 3')),
                      ],
                      onChanged: c.busy
                          ? null
                          : (v) => setState(() => family = v!),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: c.busy ? null : () => pickModel(false),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose assistant model'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Private history search',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      c.embeddings.available
                          ? 'EmbeddingGemma 2 loaded'
                          : 'EmbeddingGemma 2 needs setup',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: c.busy ? null : () => pickModel(true),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose EmbeddingGemma 2'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Web information tool',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'The assistant can search public information using Brave Search. Only the general query is sent; your reports and history stay here.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      enabled: !c.isPreview,
                      controller: keyInput,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Brave Search API key',
                        hintText: c.webSearch.available
                            ? 'A key is saved securely'
                            : 'Paste your search key',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : c.isPreview
                          ? null
                          : () => c.setWebKey(keyInput.text),
                      child: const Text('Save search key'),
                    ),
                  ],
                ),
              ),
            ),
            if (c.busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(c.activity),
            ],
            if (c.failure != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(c.failure!),
              ),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('Open-source licenses'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Ayumitra',
              ),
            ),
            const Text(
              'Profiles',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            RadioGroup<String>(
              groupValue: c.activeProfileId,
              onChanged: (v) {
                if (!c.busy && v != null) {
                  c.selectProfile(v);
                  Navigator.pop(context);
                }
              },
              child: Column(
                children: [
                  for (final profile in c.data.profiles)
                    RadioListTile<String>(
                      title: Text(profile.name),
                      value: profile.id,
                      enabled: !c.busy,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class ReportScreen extends StatelessWidget {
  const ReportScreen({
    super.key,
    required this.controller,
    required this.reportId,
  });
  final AppController controller;
  final String reportId;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final report = controller.reports
          .where((r) => r.id == reportId)
          .firstOrNull;
      if (report == null) {
        return const Scaffold(
          body: Center(
            child: Text('This report is not available in the active profile.'),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: Text(report.name)),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '${report.type} · ${ageAtEvent(controller.profile!, report.eventDate)}',
              style: const TextStyle(color: ink),
            ),
            const SizedBox(height: 8),
            Text(statusLabel(report.status)),
            if (report.notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(report.notice!),
              ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          SourceScreen(controller: controller, report: report),
                    ),
                  ),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Open original'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: controller.busy
                      ? null
                      : () => controller.retry(report),
                  child: const Text('Reprocess'),
                ),
              ],
            ),
            if (controller.busy) ...[
              const LinearProgressIndicator(),
              Text(controller.activity),
            ],
            if (report.summaryMarkdown != null) ...[
              const SizedBox(height: 24),
              Text(
                controller.isPreview
                    ? 'Sample summary · synthetic data'
                    : 'AI summary · review against sources',
                style: const TextStyle(fontSize: 12, color: ink),
              ),
              const SizedBox(height: 12),
              SelectionArea(
                child: MarkdownBody(
                  data: linkedReportSummary(report),
                  selectable: false,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                        tableColumnWidth: const IntrinsicColumnWidth(),
                        tableCellsPadding: const EdgeInsets.all(10),
                      ),
                  imageBuilder: (_, _, _) => const SizedBox.shrink(),
                  onTapLink: (_, href, _) {
                    final line = report.lines
                        .where((l) => href == 'source:${report.id}/${l.id}')
                        .firstOrNull;
                    if (line != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SourceScreen(
                            controller: controller,
                            report: report,
                            line: line,
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Extracted facts',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            if (report.facts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Structured facts will appear after a local model reads this report.',
                ),
              ),
            for (final fact in report.facts)
              Card(
                child: ListTile(
                  title: Text('${fact.name}: ${fact.value} ${fact.unit}'),
                  subtitle: Text(
                    '${fact.range.isEmpty ? 'No printed range' : 'Report range: ${fact.range}'}\n'
                    '${fact.corrected ? 'User corrected · original value ${fact.originalValue}' : 'AI extracted · check source'}',
                  ),
                  isThreeLine: true,
                  onTap: () {
                    final line = report.lines
                        .where((l) => l.id == fact.sourceLineId)
                        .firstOrNull;
                    if (line != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SourceScreen(
                            controller: controller,
                            report: report,
                            line: line,
                          ),
                        ),
                      );
                    }
                  },
                  trailing: IconButton(
                    tooltip: 'Correct value',
                    onPressed: controller.busy
                        ? null
                        : () => _correct(context, report, fact),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            const Text(
              'Source text',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            for (final line in report.lines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(line.text),
                subtitle: Text(
                  'Page ${line.page} · ${line.method == 'ocr' ? 'OCR reading' : 'PDF/text reading'}',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SourceScreen(
                      controller: controller,
                      report: report,
                      line: line,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
  Future<void> _correct(
    BuildContext context,
    Report report,
    MedicalFact fact,
  ) async {
    final input = TextEditingController(text: fact.value);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Correct ${fact.name}'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(labelText: 'Value from the report'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Save correction'),
          ),
        ],
      ),
    );
    // The dialog's exit animation may still reference its controller.
    if (value != null && value.trim().isNotEmpty) {
      await controller.correctFact(report, fact, value);
    }
  }
}

String linkedReportSummary(Report report) {
  var text = report.summaryMarkdown ?? '';
  for (final line in report.lines) {
    text = text.replaceAll(
      '[${report.id}/${line.id}]',
      '[Page ${line.page}](source:${report.id}/${line.id})',
    );
  }
  return text;
}
