import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const ReligionApp());

class GeminiRequestException implements Exception {
  final int? status;
  final String? body;
  const GeminiRequestException(this.status, this.body);
}

Future<List<String>> _getAvailableFreeModels(String apiKey) async {
  const preferred = [
    'gemini-2.5-flash',
    'gemini-2.0-flash-lite',
    'gemini-1.5-flash',
    'gemini-1.5-flash-8b',
  ];

  try {
    final response = await http
        .get(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models',
          ),
          headers: {'x-goog-api-key': apiKey},
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final models = (data['models'] as List? ?? [])
          .whereType<Map>()
          .map((model) => model['name']?.toString() ?? '')
          .where((name) => name.startsWith('models/gemini'))
          .map((name) => name.substring('models/'.length))
          .toSet()
          .toList();

      final result = preferred
          .where((model) => models.contains(model))
          .toList();
      for (final model in models) {
        final supportsLite =
            model.contains('flash-lite') && !model.contains('image');
        final supportsFlash =
            model.contains('flash') && !model.contains('image');
        if ((supportsLite || supportsFlash) &&
            !result.contains(model) &&
            (model.contains('latest') ||
                model.contains('lite') ||
                model.contains('2.5'))) {
          result.add(model);
        }
      }
      if (result.isNotEmpty) return result;
    }
  } catch (_) {}

  return preferred;
}

class ReligionApp extends StatelessWidget {
  const ReligionApp({super.key});

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF6750A4);
    return MaterialApp(
      title: 'Religion im Alltag',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'sans-serif',
        colorScheme: ColorScheme.fromSeed(seedColor: purple),
        scaffoldBackgroundColor: const Color(0xFFF7F7FA),
      ),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  final _history = _HistoryStore();

  @override
  Widget build(BuildContext context) {
    final pages = [
      _ChatPage(history: _history),
      _KnowledgePage(history: _history),
      _HistoryPage(history: _history),
      const _SettingsPage(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        height: 72,
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        indicatorColor: const Color(0xFFE8DEF8),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Analyse',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book_rounded),
            label: 'Wissen',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            label: 'Verlauf',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            selectedIcon: Icon(Icons.tune),
            label: 'Optionen',
          ),
        ],
      ),
    );
  }
}

class _HistoryStore extends ChangeNotifier {
  static const _key = 'search_history';
  List<Map<String, dynamic>> items = [];

  _HistoryStore() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    items = raw.map((item) {
      try {
        return Map<String, dynamic>.from(jsonDecode(item) as Map);
      } catch (_) {
        return <String, dynamic>{};
      }
    }).where((item) => item.isNotEmpty).toList();
    notifyListeners();
  }

  Future<void> add(String input, bool religious, String answer) async {
    items.insert(0, {
      'input': input,
      'religious': religious,
      'answer': answer,
      'time': DateTime.now().toIso8601String(),
    });
    if (items.length > 30) items.removeLast();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      items.map(jsonEncode).toList(),
    );
    notifyListeners();
  }

  Future<void> clear() async {
    items.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    notifyListeners();
  }
}

class _ChatPage extends StatefulWidget {
  final _HistoryStore history;
  const _ChatPage({required this.history});

  @override
  State<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<_ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _loading = false;
  final List<ChatMessage> _messages = [];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send([String? example]) async {
    final input = (example ?? _controller.text).trim();
    if (input.isEmpty) return;
    _controller.clear();

    setState(() {
      _messages.add(ChatMessage.user(input));
      _loading = true;
    });
    await _scrollToEnd();

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('gemini_api_key')?.trim() ?? '';
    if (apiKey.isEmpty) {
      setState(() {
        _loading = false;
        _messages.add(const ChatMessage.assistant(
          'Noch kein Gemini-Key gespeichert. Öffne Optionen und füge deinen API-Key ein.',
          false,
          'Hinweis',
        ));
      });
      return;
    }

    final prompt = '''
Du bist ein sachlicher Religionsdidaktik-Assistent fuer Jugendliche.
Analysiere diesen Alltagseindruck, Song oder Filmtitel:
"$input"

Antworte NUR als JSON:
{"religious":true oder false,"answer":"Eine klare Antwort auf Deutsch, maximal vier kurze Saetze."}

Starte mit "Ja," oder "Nein,".
Unterscheide sichtbare Institution, sichtbare religioese Praxis und latente Deutungsmuster.
Erfinde keine Fakten ueber das Werk oder den Inhalt.
Begrunde bei "Nein" den profanen Bezug.
Sei neutral und kulturbezogen.
''';

    try {
      http.Response? response;
      final freeModels = await _getAvailableFreeModels(apiKey);
      int? lastStatus;
      String? lastBody;
      for (final model in freeModels) {
        response = await http.post(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
          ),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
            'generationConfig': {
              'temperature': 0.3,
              'responseMimeType': 'application/json',
            },
          }),
        );
        lastStatus = response.statusCode;
        if (response.statusCode == 200) break;
        lastBody = response.body;
      }
      if (response == null || response.statusCode != 200) {
        throw GeminiRequestException(lastStatus, lastBody);
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final candidate = (data['candidates'] as List).first as Map<String, dynamic>;
      final content = candidate['content'] as Map<String, dynamic>;
      final parts = content['parts'] as List;
      final text = (parts.first as Map<String, dynamic>)['text'] as String;
      final clean = text
          .replaceFirst(RegExp(r'^```json\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
      final result = jsonDecode(clean) as Map<String, dynamic>;
      final religious = result['religious'] == true;
      final answer = result['answer']?.toString() ?? text;

      await widget.history.add(input, religious, answer);
      setState(() {
        _loading = false;
        _messages.add(ChatMessage.assistant(
          answer,
          religious,
          religious ? 'Religioese Spur gefunden' : 'Eher profaner Bezug',
        ));
      });
      await _scrollToEnd();
    } catch (error) {
      final message = switch (error) {
        GeminiRequestException(status: final status, body: final body) =>
          'Gemini hat HTTP $status zurückgegeben. Prüfe den API-Key, die API-Aktivierung und das Modell. ${body ?? ''}',
        _ => 'Die Anfrage konnte nicht verarbeitet werden. Prüfe Internetverbindung und API-Konfiguration.',
      };
      setState(() {
        _loading = false;
        _messages.add(ChatMessage.assistant(
          message,
          false,
          'Verbindung pruefen',
        ));
      });
    }
  }

  Future<void> _scrollToEnd() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6750A4),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.psychology_alt_rounded,
                      color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Religion im Alltag',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                      Text('Woran erkennst du religioese Spuren?',
                          style: TextStyle(
                              color: Color(0xFF777381), fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              children: [
                if (_messages.isEmpty) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Was möchtest du untersuchen?',
                    style: TextStyle(
                        fontSize: 26,
                        height: 1.15,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Gib einen Song, einen Film oder einen Alltagseindruck ein.',
                    style: TextStyle(color: Color(0xFF777381)),
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SuggestionChip(
                        label: 'Like a Prayer',
                        icon: Icons.music_note_rounded,
                        onTap: () => _send('Like a Prayer von Madonna'),
                      ),
                      _SuggestionChip(
                        label: 'Back to the 90s',
                        icon: Icons.movie_outlined,
                        onTap: () => _send('Back to the 90s'),
                      ),
                      _SuggestionChip(
                        label: 'Festival',
                        icon: Icons.celebration_outlined,
                        onTap: () => _send('Rituelle Erlebnisse auf einem Festival'),
                      ),
                    ],
                  ),
                ],
                ..._messages.map((message) => _ChatBubble(message: message)),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE8E6ED))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Nachricht eingeben...',
                      filled: true,
                      fillColor: const Color(0xFFF3F1F7),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkResponse(
                  onTap: _loading ? null : () => _send(),
                  radius: 26,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0xFF6750A4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.arrow_upward_rounded,
                        color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool? isUser;
  final bool? religious;
  final String? label;

  const ChatMessage.user(this.text)
      : isUser = true,
        religious = null,
        label = null;
  const ChatMessage.assistant(this.text, this.religious, this.label)
      : isUser = false;
}

class _SuggestionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _SuggestionChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      onPressed: onTap,
      avatar: Icon(icon, size: 18, color: const Color(0xFF6750A4)),
      label: Text(label),
      backgroundColor: const Color(0xFFF0ECF7),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser == true;
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          constraints: const BoxConstraints(maxWidth: 290),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF6750A4),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(message.text,
              style: const TextStyle(color: Colors.white, height: 1.35)),
        ),
      );
    }

    final positive = message.religious == true;
    final accent =
        positive ? const Color(0xFF6750A4) : const Color(0xFF507A84);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 7),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border(left: BorderSide(color: accent, width: 4)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message.label ?? '',
              style: TextStyle(
                  color: accent, fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 6),
          Text(message.text,
              style: const TextStyle(
                  color: Color(0xFF3E3948), height: 1.42, fontSize: 15)),
        ],
      ),
    );
  }
}

class _KnowledgePage extends StatelessWidget {
  final _HistoryStore history;
  const _KnowledgePage({required this.history});

  @override
  Widget build(BuildContext context) {
    final topics = [
      _KnowledgeTopic(
        'Rituale',
        'Wiederholte Handlungen schaffen Zugehörigkeit, Ordnung und Bedeutung.',
        Icons.refresh_rounded,
        const Color(0xFFE9DEF7),
        const Color(0xFF6750A4),
      ),
      _KnowledgeTopic(
        'Gemeinschaft',
        'Feste, Vereine und Fanszenen können gemeinschaftsstiftend wirken.',
        Icons.groups_rounded,
        const Color(0xFFDDECF0),
        const Color(0xFF477A87),
      ),
      _KnowledgeTopic(
        'Symbole',
        'Gegenstände und Bilder können Werte oder Erinnerungen verdichten.',
        Icons.diamond_outlined,
        const Color(0xFFFFE7DA),
        const Color(0xFFA95F37),
      ),
      _KnowledgeTopic(
        'Transzendenz',
        'Grenzerfahrungen verweisen auf das, was Menschen als größer erleben.',
        Icons.auto_awesome_outlined,
        const Color(0xFFE4EEDB),
        const Color(0xFF5D7847),
      ),
      _KnowledgeTopic(
        'Deutung',
        'Geschichten helfen Menschen, Lebenserfahrungen zu ordnen.',
        Icons.auto_stories_outlined,
        const Color(0xFFF1E1D8),
        const Color(0xFF946849),
      ),
      _KnowledgeTopic(
        'Nicht-religiös',
        'Profan bedeutet nicht wertlos: Es zeigt Alltagsbereiche ohne Religionsbezug.',
        Icons.light_mode_outlined,
        const Color(0xFFE6E8ED),
        const Color(0xFF626976),
      ),
      _KnowledgeTopic(
        'Musik',
        'Lieder, Konzerte und Festivals können starke Emotionen und Gemeinschaft erzeugen.',
        Icons.music_note_rounded,
        const Color(0xFFF3E5F5),
        const Color(0xFF7B1FA2),
      ),
      _KnowledgeTopic(
        'Film & Kino',
        'Filme erzählen Geschichten, die Werte, Ängste und Träume spiegeln.',
        Icons.movie_outlined,
        const Color(0xFFE3F2FD),
        const Color(0xFF1565C0),
      ),
      _KnowledgeTopic(
        'Kunst & Museen',
        'Kunstwerke regen zum Nachdenken an und können spirituelle Erfahrungen vermitteln.',
        Icons.edit_outlined,
        const Color(0xFFF1F8E9),
        const Color(0xFF33691E),
      ),
      _KnowledgeTopic(
        'Web & Social Media',
        'Digitale Räume schaffen neue Formen von Gemeinschaft, Ritual und Deutung.',
        Icons.web_outlined,
        const Color(0xFFFCE4EC),
        const Color(0xFF880E4F),
      ),
      _KnowledgeTopic(
        'Sport & Fanszenen',
        'Sportveranstaltungen wirken wie moderne Rituale mit gemeinschaftlichem Erleben.',
        Icons.sports_soccer_outlined,
        const Color(0xFFE0F2F1),
        const Color(0xFF00695C),
      ),
      _KnowledgeTopic(
        'Mode & Stil',
        'Kleidung und Accessoires können Identität, Zugehörigkeit und Werte ausdrücken.',
        Icons.checkroom_outlined,
        const Color(0xFFFFF3E0),
        const Color(0xFFE65100),
      ),
      _KnowledgeTopic(
        'Essen & Kulinarik',
        'Gemeinsames Essen schafft Verbindung und kann rituelle Bedeutung haben.',
        Icons.restaurant_outlined,
        const Color(0xFFFFEBEE),
        const Color(0xFFB71C1C),
      ),
      _KnowledgeTopic(
        'Reisen & Orte',
        'Besondere Orte und Reisen können Perspektiven erweitern und Sinn stiften.',
        Icons.flight_takeoff_outlined,
        const Color(0xFFF3E5F5),
        const Color(0xFF4A148C),
      ),
      _KnowledgeTopic(
        'Natur & Jahreszeiten',
        'Naturerlebnisse und Jahreszeitenzyklen können Demut und Staunen auslösen.',
        Icons.nature_outlined,
        const Color(0xFFE8F5E9),
        const Color(0xFF2E7D32),
      ),
      _KnowledgeTopic(
        'Arbeit & Büro',
        'Der Arbeitsalltag hat eigene Rhythmen, Hierarchien und gemeinschaftliche Momente.',
        Icons.work_outlined,
        const Color(0xFFF5F5F5),
        const Color(0xFF424242),
      ),
      _KnowledgeTopic(
        'Schule & Universität',
        'Bildungsräume vermitteln Wissen, Werte und formen die Identität junger Menschen.',
        Icons.school_outlined,
        const Color(0xFFE1F5FE),
        const Color(0xFF0277BD),
      ),
      _KnowledgeTopic(
        'Familie & Feiern',
        'Familientraditionen und Feiertage schaffen Verbundenheit und Erinnerungskultur.',
        Icons.people_outlined,
        const Color(0xFFFFFDE7),
        const Color(0xFFF57F17),
      ),
      _KnowledgeTopic(
        'Technik & Geräte',
        'Smartphones und Technik begleiten den Alltag und verändern, wie wir kommunizieren.',
        Icons.devices_outlined,
        const Color(0xFFF3E5F5),
        const Color(0xFF4A148C),
      ),
      _KnowledgeTopic(
        'Spiele & Gaming',
        'Videospiele schaffen immersive Welten mit eigenen Regeln, Helden und Gemeinschaften.',
        Icons.videogame_asset_outlined,
        const Color(0xFFE8F5E9),
        const Color(0xFF1B5E20),
      ),
      _KnowledgeTopic(
        'Bücher & Literatur',
        'Geschichten in Büchern helfen, Lebensfragen zu stellen und Antworten zu suchen.',
        Icons.library_books_outlined,
        const Color(0xFFFFF8E1),
        const Color(0xFFF9A825),
      ),
      _KnowledgeTopic(
        'Architektur & Räume',
        'Gebäude und öffentliche Räume prägen, wie wir uns fühlen und begegnen.',
        Icons.apartment_outlined,
        const Color(0xFFEFEBE9),
        const Color(0xFF5D4037),
      ),
    ];

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          const Text('Wissensdatenbank',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            'Religion begegnet uns nicht nur in der Kirche.',
            style: TextStyle(color: Color(0xFF777381)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6750A4), Color(0xFF8272BA)],
              ),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Der Alltag hat drei Ebenen',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 10),
                Text(
                  'Institutionell · praktisch · latent',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4),
                ),
                SizedBox(height: 8),
                Text(
                  'Nicht alles Religiöse wirkt kirchlich. Suche nach Gemeinschaft, Ritual, Symbol und Sinn.',
                  style: TextStyle(color: Color(0xFFF2EFFA), height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          ...topics.map((topic) => _KnowledgeCard(topic: topic)),
        ],
      ),
    );
  }
}

class _KnowledgeTopic {
  final String title;
  final String text;
  final IconData icon;
  final Color background;
  final Color foreground;

  const _KnowledgeTopic(
      this.title, this.text, this.icon, this.background, this.foreground);
}

class _KnowledgeCard extends StatelessWidget {
  final _KnowledgeTopic topic;
  const _KnowledgeCard({required this.topic});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _KnowledgeDetailPage(topic: topic),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: topic.background,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(topic.icon, color: topic.foreground),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(topic.title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(topic.text,
                          style: const TextStyle(
                              color: Color(0xFF777381), height: 1.35)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFFA9A4B2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopicDetail {
  final String title;
  final String text;
  final IconData icon;
  const _TopicDetail({required this.title, required this.text, required this.icon});
}

/// Ein Song-Beispiel für das Thema Musik mit Angabe, ob es als profan gilt
/// und welcher Eindruck entsteht (auch wenn es nicht profan ist).
class _MusicSong {
  final String title;
  final String artist;
  final bool profane;
  final String profaneText;        // Antwort auf: Wann ist es profan?
  final String notProfaneText;     // Nicht profan – obwohl oft gedacht
  const _MusicSong({
    required this.title,
    required this.artist,
    required this.profane,
    required this.profaneText,
    required this.notProfaneText,
  });
}

const List<_MusicSong> musicSongs = [
  _MusicSong(
    title: 'Like a Prayer',
    artist: 'Madonna',
    profane: true,
    profaneText:
        'Der Song nutzt religiöse Symbole wie Kreuze und Stigmata im Pop-Kontext, ohne eigentlichen Gottesbezug. Das kann als profane Umdeutung religiöser Bilder gelesen werden.',
    notProfaneText:
        'Die religiösen Bilder drücken persönliche Sehnsucht und spirituelle Erfahrung aus – es ist keine Gotteslästerung. Viele hören darin ein echtes Gebet.',
  ),
  _MusicSong(
    title: 'Hallelujah',
    artist: 'Leonard Cohen',
    profane: true,
    profaneText:
        'Obwohl „Hallelujah“ ein Lobgesang auf Gott ist, singt Cohen hier von Liebe, Sex und Trennung. In diesem weltlichen Kontext wirkt der Begriff profan.',
    notProfaneText:
        'Das Wort „Hallelujah“ selbst ist religiös. Der Song kann auch als spirituelle Suche nach Trost gelesen werden – nicht automatisch profan.',
  ),
  _MusicSong(
    title: 'Take Me to Church',
    artist: 'Hozier',
    profane: true,
    profaneText:
        'Die Kirche wird hier als Metapher für eine körperliche Beziehung genutzt. Religiöse Sprache wird weltlich und profan umgedeutet.',
    notProfaneText:
        'Der Song kritisiert kirchliche Dogmen und plädiert für bedingungslose Liebe. Das ist eine ernsthafte, nicht profane Auseinandersetzung mit Religion.',
  ),
  _MusicSong(
    title: 'Amazing Grace',
    artist: 'Traditionell',
    profane: false,
    profaneText:
        '– (keine; der Text handelt klar von Gnade und Erlösung und ist religiös geprägt).',
    notProfaneText:
        'Obwohl es ein Kirchenlied ist, denken manche, es sei „nur altmodisch“ oder profan. Tatsächlich ist es ein religiöses Gotteslied.',
  ),
  _MusicSong(
    title: 'Kyrie',
    artist: 'Mr. Mister',
    profane: true,
    profaneText:
        'Der Song nutzt den religiösen Ruf „Kyrie eleison“ (Herr, erbarme dich) im Kontext einer Liebesbeziehung. Religiöse Sprache wird profan umgedeutet.',
    notProfaneText:
        'Der Refrain kann als echter Hilferuf und spirituelle Sehnsucht gelesen werden – nicht automatisch profan.',
  ),
];

/// Zeigt ein einzelnes Song-Beispiel als antippbare Karte an.
class _MusicSongCard extends StatelessWidget {
  final _MusicSong song;
  final VoidCallback onTap;
  const _MusicSongCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent =
        song.profane ? const Color(0xFFB71C1C) : const Color(0xFF1B5E20);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withOpacity(0.3), width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  song.profane ? 'profan' : 'nicht profan',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${song.title} – ${song.artist}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: Color(0xFF3E3948)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.profane
                          ? 'Wann ist es profan?'
                          : 'Nicht profan – obwohl oft gedacht',
                      style: TextStyle(
                          color: Color(0xFF777381),
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: Color(0xFFA9A4B2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Öffnet einen Dialog mit den Details zu profan / nicht profan für einen Song.
void _showSongDialog(BuildContext context, _MusicSong song) {
  final accent =
      song.profane ? const Color(0xFFB71C1C) : const Color(0xFF1B5E20);
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('${song.title} – ${song.artist}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                song.profane ? 'Status: profan' : 'Status: nicht profan',
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Wann ist es profan?',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: Color(0xFF3E3948)),
            ),
            const SizedBox(height: 6),
            Text(
              song.profaneText,
              style: const TextStyle(
                  height: 1.4, color: Color(0xFF4D4857), fontSize: 14),
            ),
            const SizedBox(height: 16),
            const Text(
              'Nicht profan – obwohl oft gedacht',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: Color(0xFF3E3948)),
            ),
            const SizedBox(height: 6),
            Text(
              song.notProfaneText,
              style: const TextStyle(
                  height: 1.4, color: Color(0xFF4D4857), fontSize: 14),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
}

class _KnowledgeDetailPage extends StatelessWidget {
  final _KnowledgeTopic topic;
  const _KnowledgeDetailPage({required this.topic});

  @override
  Widget build(BuildContext context) {
    final examples = switch (topic.title) {
      'Rituale' => const [
          'Ein Konzert beginnt mit gemeinsamen Rhythmen.',
          'Zum Jahreswechsel wiederholen Menschen bestimmte Traditionen.',
          'Ein Stadionbesuch kann feste Abläufe und Gemeinschaft schaffen.',
        ],
      'Gemeinschaft' => const [
          'Fanclubs erleben Zugehörigkeit ähnlich wie Gruppenrituale.',
          'Vereine verbinden gemeinsame Werte und regelmäßige Treffen.',
          'Feste schaffen Erlebnisse von „wir gehören zusammen“. ',
        ],
      'Symbole' => const [
          'Ein Konzertarmband kann Erinnerung und Identität bündeln.',
          'Herzen, Kreuze oder Emojis können ganz unterschiedliche Bedeutungen tragen.',
          'Album-Cover können Deutungen und Sehnsüchte sichtbar machen.',
        ],
      'Transzendenz' => const [
          'Ein großes Naturerlebnis kann ein Gefühl des Überschreitens auslösen.',
          'Musik kann Momente schaffen, die Menschen als besonders erleben.',
          'Grenzfragen können in Kunst und Alltag auftauchen.',
        ],
      'Deutung' => const [
          'Nostalgie erklärt Vergangenes und gibt Gegenwart Bedeutung.',
          'Heldengeschichten ordnen Werte und Erwartungen.',
          'Memes und Filme können Sinnangebote in verkürzter Form vermitteln.',
        ],
      'Nicht-religiös' => const [
          'Viele Alltagsbereiche sind profan und nicht automatisch religiös.',
          'Eine Alltagsanalyse sollte keine Absichten oder Glaubensinhalte erfinden.',
          'Profan kann wertvoll sein, auch ohne religiöse Bedeutung.',
        ],
      'Musik' => const [
          'Like a Prayer – Madonna',
          'Hallelujah – Leonard Cohen',
          'Take Me to Church – Hozier',
          'Amazing Grace – Traditionell',
          'Kyrie – Mr. Mister',
          'Imagine – John Lennon',
          'Stairway to Heaven – Led Zeppelin',
          'Losing My Religion – R.E.M.',
          'Jesus Walks – Kanye West',
          'Spirit in the Sky – Norman Greenbaum',
          'Sweet Child O\' Mine – Guns N\' Roses',
          'Bohemian Rhapsody – Queen',
          'Halo – Beyoncé',
          'Angel – Sarah McLachlan',
          'Oh Happy Day – Edwin Hawkins Singers',
          'Shallow – Lady Gaga',
          'Blessed – Elton John',
          'Judas – Lady Gaga',
          'Holy – Justin Bieber',
          'Ave Maria – Schubert',
          'Stand by Me – Ben E. King',
          'I Can Only Imagine – MercyMe',
          'Cathedral – ...',
          'Prayer – ...',
          'Gospel – ...',
          'Heaven – ...',
          'Salvation – ...',
          'Cross Road Blues – ...',
          'Psalm 23 – ...',
          'Amen – ...',
        ],
      'Film & Kino' => const [
          'Filme erzählen Geschichten, die Werte, Ängste und Träume spiegeln.',
          'Kinobesuche sind gemeinsame Rituale mit Popcorn und Vorfreude.',
          'Heldenreisen in Filmen können Orientierung im echten Leben geben.',
        ],
      'Kunst & Museen' => const [
          'Kunstwerke regen zum Nachdenken an und können spirituelle Erfahrungen vermitteln.',
          'Ein Museumsgang kann Ruhe und Kontemplation im Alltag bieten.',
          'Farben und Formen in Gemälden können Stimmungen auslösen.',
        ],
      'Web & Social Media' => const [
          'Digitale Räume schaffen neue Formen von Gemeinschaft, Ritual und Deutung.',
          'Hashtags können Bewegungen sammeln und Sichtbarkeit erzeugen.',
          'Online-Memes drücken gemeinsame Stimmungen und Humor aus.',
        ],
      'Sport & Fanszenen' => const [
          'Sportveranstaltungen wirken wie moderne Rituale mit gemeinschaftlichem Erleben.',
          'Fangruppen schaffen starke Identität und Zusammengehörigkeit.',
          'Siegfeiern können kollektive Euphorie auslösen.',
        ],
      'Mode & Stil' => const [
          'Kleidung und Accessoires können Identität, Zugehörigkeit und Werte ausdrücken.',
          'Ein bestimmter Stil kann Zugehörigkeit zu einer Szene signalisieren.',
          'Schmuck kann persönliche Bedeutung oder Erinnerungen tragen.',
        ],
      'Essen & Kulinarik' => const [
          'Gemeinsames Essen schafft Verbindung und kann rituelle Bedeutung haben.',
          'Familienessen am Wochenende können Zusammenhalt stärken.',
          'Festtagskochen verbindet Generationen und Traditionen.',
        ],
      'Reisen & Orte' => const [
          'Besondere Orte und Reisen können Perspektiven erweitern und Sinn stiften.',
          'Wallfahrtsorte ziehen Menschen an, die Suche und Sinn erleben wollen.',
          'Ein Besuch an einem historischen Ort kann Demut und Staunen auslösen.',
        ],
      'Natur & Jahreszeiten' => const [
          'Naturerlebnisse und Jahreszeitenzyklen können Demut und Staunen auslösen.',
          'Der erste Schnee kann Vorfreude und kindliche Freude wecken.',
          'Herbstblätter können Vergänglichkeit und Wandel symbolisieren.',
        ],
      'Arbeit & Büro' => const [
          'Der Arbeitsalltag hat eigene Rhythmen, Hierarchien und gemeinschaftliche Momente.',
          'Die Kaffeepause im Büro kann soziale Bindungen stärken.',
          'Projektabschlüsse werden oft gemeinsam gefeiert.',
        ],
      'Schule & Universität' => const [
          'Bildungsräume vermitteln Wissen, Werte und formen die Identität junger Menschen.',
          'Abschlussfeiern markieren Übergänge und Errungenschaften.',
          'Gemeinsames Lernen kann Gemeinschaft und gegenseitige Unterstützung schaffen.',
        ],
      'Familie & Feiern' => const [
          'Familientraditionen und Feiertage schaffen Verbundenheit und Erinnerungskultur.',
          'Geburtstage feiern das Leben und die individuelle Person.',
          'Weihnachten oder andere Feste können Zusammenhalt symbolisieren.',
        ],
      'Technik & Geräte' => const [
          'Smartphones und Technik begleiten den Alltag und verändern, wie wir kommunizieren.',
          'Die morgendliche Nachrichtencheck-Routine kann Struktur geben.',
          'Digitale Erinnerungen (Fotos, Videos) bewahren Momente.',
        ],
      'Spiele & Gaming' => const [
          'Videospiele schaffen immersive Welten mit eigenen Regeln, Helden und Gemeinschaften.',
          'Gemeinsames Spielen kann Teamgefühl und Zusammenarbeit fördern.',
          'Spielerfolge können Selbstwirksamkeit und Stolz vermitteln.',
        ],
      'Bücher & Literatur' => const [
          'Geschichten in Büchern helfen, Lebensfragen zu stellen und Antworten zu suchen.',
          'Romane können Empathie für andere Lebenswelten wecken.',
          'Sachbücher können Wissen und Orientierung bieten.',
        ],
      'Architektur & Räume' => const [
          'Gebäude und öffentliche Räume prägen, wie wir uns fühlen und begegnen.',
          'Kirchen, Moscheen oder Tempel können Orte der Stille sein.',
          'Marktplätze können Zentren des öffentlichen Lebens sein.',
        ],
      _ => const [
          'Viele Alltagsbereiche sind profan und nicht automatisch religiös.',
          'Eine Alltagsanalyse sollte keine Absichten oder Glaubensinhalte erfinden.',
          'Profan kann wertvoll sein, auch ohne religiöse Bedeutung.',
        ],
    };

    final religiousInfo = switch (topic.title) {
      'Rituale' => const _TopicDetail(
        title: 'Was Rituale religiös machen kann',
        text: 'Rituale schaffen Wiederholung, Ordnung und Bedeutung. Sie verbinden Menschen über Generationen hinweg und können Übergänge im Leben markieren – wie Geburt, Erwachsenwerden oder Tod. In Religionen sind Rituale oft heilige Handlungen, aber auch im Alltag können sie Tiefe und Struktur schenken.',
        icon: Icons.refresh_rounded,
      ),
      'Gemeinschaft' => const _TopicDetail(
        title: 'Was Gemeinschaft religiös machen kann',
        text: 'Gemeinschaft gibt Halt und Zugehörigkeit. Religiöse Gemeinschaften feiern Feste, teilen Werte und sorgen füreinander. Auch Fanclubs, Vereine oder Nachbarschaften erleben „wir-Gefühle“, die stark an religiöse Gemeinschaften erinnern können.',
        icon: Icons.groups_rounded,
      ),
      'Symbole' => const _TopicDetail(
        title: 'Was Symbole religiös machen kann',
        text: 'Symbole verdichten Bedeutung in einem Bild oder Gegenstand. Ein Kreuz, ein Halbmond, ein Herz oder ein Konzertarmband können Hoffnung, Liebe oder Erinnerung tragen. Symbole sprechen oft direkter an als Worte und können spirituelle Erfahrungen auslösen.',
        icon: Icons.diamond_outlined,
      ),
      'Transzendenz' => const _TopicDetail(
        title: 'Was Transzendenz religiös machen kann',
        text: 'Transzendenz bedeutet, über das Alltägliche hinauszugehen. Ein Sternenhimmel, eine große Natur oder ein bewegender Musikmoment können das Gefühl erwecken, Teil von etwas Größerem zu sein. Viele Religionen beschreiben genau diese Erfahrung als göttlich oder spirituell.',
        icon: Icons.auto_awesome_outlined,
      ),
      'Deutung' => const _TopicDetail(
        title: 'Was Deutung religiös machen kann',
        text: 'Menschen deuten ihr Leben, um Sinn zu finden. Geschichten, Mythen und persönliche Erfahrungen helfen, Erlebnisse einzuordnen. Religiöse Deutungen fragen nach dem Warum und dem Wozu – auch im Alltag suchen Menschen nach Bedeutung hinter Ereignissen.',
        icon: Icons.auto_stories_outlined,
      ),
      'Nicht-religiös' => const _TopicDetail(
        title: 'Warum der profane Alltag wertvoll ist',
        text: 'Nicht alles im Alltag ist religiös – und das ist gut so. Ein Supermarktbesuch, Zähneputzen oder der Weg zur Arbeit sind funktionale Handlungen ohne spirituelle Bedeutung. Profanität erlaubt es, das Leben in seiner schlichten Normalität zu schätzen, ohne jede Handlung zu überdeuten.',
        icon: Icons.light_mode_outlined,
      ),
      'Musik' => const _TopicDetail(
        title: 'Profane Musik vs. religiöse Musik',
        text:
            'Nicht jede Musik mit religiösen Worten ist automatisch religiös – und nicht jede profane Musik ist wertlos. Ein Song kann religiöse Symbole nutzen, um weltliche Gefühle auszudrücken (profan), oder er kann eine echte spirituelle Sehnsucht transportieren (nicht profan). Die Entscheidung liegt im Kontext: Wird Gott angerufen oder nur ein Bild geborgt? Unten finden Sie fünf Song-Beispiele. Tippen Sie auf einen Song, um zu sehen, wann er als profan gilt und warum er dennoch nicht profan sein kann.',
        icon: Icons.music_note_rounded,
      ),
      'Film & Kino' => const _TopicDetail(
        title: 'Was Filme religiös machen kann',
        text: 'Filme erzählen Geschichten über Helden, Leiden, Liebe und Sinnsuche. Kinobesuche wirken wie moderne Rituale mit gemeinsamen Erwartungen und Erlebnissen. Viele Filme greifen religiöse Motive auf – von der Suche nach dem Sinn des Lebens bis hin zu Opfer und Erlösung.',
        icon: Icons.movie_outlined,
      ),
      'Kunst & Museen' => const _TopicDetail(
        title: 'Was Kunst religiös machen kann',
        text: 'Kunst regt zum Nachdenken an und kann Kontemplation auslösen. Religiöse Kunst zeigt oft biblische oder spirituelle Szenen, aber auch moderne Werke können Fragen nach dem Sinn des Lebens stellen. Museen bieten Räume für Stille und Begegnung mit sich selbst.',
        icon: Icons.edit_outlined,
      ),
      'Web & Social Media' => const _TopicDetail(
        title: 'Was digitale Räume religiös machen kann',
        text: 'Social Media schafft neue Formen von Gemeinschaft und Ritual. Hashtags sammeln Bewegungen, Memes drücken gemeinsame Stimmungen aus, und digitale Gedenkseiten zeigen, wie Trauer online geteilt wird. Influencer können zu Identifikationsfiguren werden – fast wie moderne Heilige.',
        icon: Icons.web_outlined,
      ),
      'Sport & Fanszenen' => const _TopicDetail(
        title: 'Was Sport religiös machen kann',
        text: 'Sportveranstaltungen wirken wie moderne Rituale: gemeinsame Gesänge, feste Abläufe, kollektive Euphorie beim Sieg und gemeinsames Leiden bei der Niederlage. Fangruppen erleben starke Identität und Zusammengehörigkeit, die stark an religiöse Gemeinschaften erinnert.',
        icon: Icons.sports_soccer_outlined,
      ),
      'Mode & Stil' => const _TopicDetail(
        title: 'Was Mode religiös machen kann',
        text: 'Kleidung und Accessoires drücken Identität und Werte aus. Ein bestimmter Stil kann Zugehörigkeit zu einer Szene signalisieren, Schmuck kann persönliche Bedeutung tragen. Uniformen oder religiöse Kleidung markieren Rolle und Funktion – Mode kann also mehr sein als nur Oberflächlichkeit.',
        icon: Icons.checkroom_outlined,
      ),
      'Essen & Kulinarik' => const _TopicDetail(
        title: 'Was Essen religiös machen kann',
        text: 'Gemeinsames Essen schafft Verbindung und Erinnerung. Festtagskochen verbindet Generationen, Familienessen stärkt Zusammenhalt. In vielen Religionen haben Mahlzeiten eine heilige Bedeutung – vom Abendmahl bis zum Fastenbrechen. Essen kann also mehr sein als Nahrungsaufnahme.',
        icon: Icons.restaurant_outlined,
      ),
      'Reisen & Orte' => const _TopicDetail(
        title: 'Was Reisen religiös machen kann',
        text: 'Besondere Orte ziehen Menschen an, die Suche und Sinn erleben wollen. Wallfahrtsorte, historische Stätten oder Orte der Natur können Demut und Staunen auslösen. Reisen erweitert den Horizont und kann zur inneren Einkehr werden – fast wie eine moderne Pilgerreise.',
        icon: Icons.flight_takeoff_outlined,
      ),
      'Natur & Jahreszeiten' => const _TopicDetail(
        title: 'Was Natur religiös machen kann',
        text: 'Naturerlebnisse lösen oft Demut und Staunen aus. Jahreszeitenzyklen zeigen Wandel und Vergänglichkeit, aber auch Neubeginn und Hoffnung. Viele Religionen sehen in der Natur ein Zeichen für etwas Göttliches oder Spirituelles – einen Schöpfungsplan oder eine höhere Ordnung.',
        icon: Icons.nature_outlined,
      ),
      'Arbeit & Büro' => const _TopicDetail(
        title: 'Was Arbeit religiös machen kann',
        text: 'Der Arbeitsalltag hat eigene Rhythmen und Rituale. Kaffeepausen schaffen soziale Bindungen, Projektabschlüsse werden gefeiert. Arbeit kann Sinn stiften und Gemeinschaft erzeugen. In manchen Religionen wird Arbeit als Berufung oder Dienst an der Gemeinschaft verstanden.',
        icon: Icons.work_outlined,
      ),
      'Schule & Universität' => const _TopicDetail(
        title: 'Was Bildung religiös machen kann',
        text: 'Bildungsräume vermitteln nicht nur Wissen, sondern auch Werte. Abschlussfeiern markieren wichtige Übergänge im Leben. Lehrer können wichtige Bezugspersonen sein. Lernen und Wachsen können als geistige Reise verstanden werden, die die Identität formt.',
        icon: Icons.school_outlined,
      ),
      'Familie & Feiern' => const _TopicDetail(
        title: 'Was Familie religiös machen kann',
        text: 'Familientraditionen und Feiertage schaffen Verbundenheit über Generationen hinweg. Geburtstage feiern das individuelle Leben, Feiertage wie Weihnachten symbolisieren Zusammenhalt. Familie kann als erste Gemeinschaft erfahren werden, in der Werte weitergegeben werden.',
        icon: Icons.people_outlined,
      ),
      'Technik & Geräte' => const _TopicDetail(
        title: 'Was Technik religiös machen kann',
        text: 'Smartphones und Technik begleiten den Alltag und verändern Kommunikation. Digitale Erinnerungen bewahren Momente, Gruppenchats erzeugen täglichen Austausch. Technik kann auch Ablenkung sein – bewusste technikfreie Zeiten können Präsenz und Achtsamkeit fördern, ähnlich wie meditative Praktiken.',
        icon: Icons.devices_outlined,
      ),
      'Spiele & Gaming' => const _TopicDetail(
        title: 'Was Gaming religiös machen kann',
        text: 'Videospiele schaffen immersive Welten mit eigenen Regeln und Helden. Gemeinsames Spielen fördert Teamgefühl, Spielerfolge vermitteln Stolz. Online-Gilden erleben digitale Gemeinschaft. Spielewelten können Orte der Erholung sein, aber auch Räume, in denen Werte erprobt werden.',
        icon: Icons.videogame_asset_outlined,
      ),
      'Bücher & Literatur' => const _TopicDetail(
        title: 'Was Bücher religiös machen kann',
        text: 'Geschichten helfen, Lebensfragen zu stellen und Antworten zu suchen. Romane wecken Empathie, Sachbücher bieten Orientierung. Religiöse Texte wie Bibel, Koran oder Tora sind Grundlage vieler Glaubensrichtungen. Bücher können Lebensbegleiter werden und Sinn stiften.',
        icon: Icons.library_books_outlined,
      ),
      'Architektur & Räume' => const _TopicDetail(
        title: 'Was Architektur religiös machen kann',
        text: 'Gebäude und öffentliche Räume prägen Gefühle und Begegnungen. Kirchen, Moscheen oder Tempel sind Orte der Stille und Spiritualität. Marktplätze sind Zentren des öffentlichen Lebens. Wohnzimmer können Orte der Geborgenheit sein – Räume können also mehr sein als nur funktionale Hülle.',
        icon: Icons.apartment_outlined,
      ),
      _ => const _TopicDetail(
        title: 'Alltag neutral betrachten',
        text: 'Religionserkennung bedeutet, kulturelle Formen neutral zu beschreiben. Nicht jeder Alltagseindruck ist automatisch religiös. Profane Bereiche sind wertvoll, auch ohne spirituelle Bedeutung. Die Analyse sollte offen und wertfrei bleiben.',
        icon: Icons.info_outlined,
      ),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(topic.title),
        backgroundColor: const Color(0xFFF7F7FA),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: topic.background,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(topic.icon, size: 42, color: topic.foreground),
                const SizedBox(height: 14),
                Text(topic.title,
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(topic.text,
                    style: const TextStyle(
                        height: 1.45,
                        color: Color(0xFF4D4857),
                        fontSize: 16)),
              ],
            ),
          ),
          const SizedBox(height: 22),
          if (topic.title == 'Musik') ...[
            // Detaillierte Beschreibung oben
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: topic.background.withOpacity(0.3),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: topic.foreground.withOpacity(0.4),
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: topic.foreground.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          religiousInfo.icon,
                          color: topic.foreground,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          religiousInfo.title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: topic.foreground,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    religiousInfo.text,
                    style: TextStyle(
                      height: 1.5,
                      color: Color(0xFF4D4857),
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text('5 Song-Beispiele',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ...musicSongs.map(
              (song) => _MusicSongCard(
                song: song,
                onTap: () => _showSongDialog(context, song),
              ),
            ),
          ] else ...[
            const Text('Beispiele',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ...examples.map(
              (example) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle_outline_rounded,
                        color: topic.foreground, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(example,
                          style: const TextStyle(
                              height: 1.35, color: Color(0xFF4D4857))),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          if (topic.title != 'Musik')
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: topic.background.withOpacity(0.3),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: topic.foreground.withOpacity(0.4),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: topic.foreground.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        religiousInfo.icon,
                        color: topic.foreground,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        religiousInfo.title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: topic.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  religiousInfo.text,
                  style: TextStyle(
                    height: 1.5,
                    color: Color(0xFF4D4857),
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F7FA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.lightbulb_outline_rounded,
                        color: Color(0xFFF9A825),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Zum Nachdenken',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF4D4857),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ..._reflectionQuestions(topic.title).map(
                  (question) => Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F7FA),
                      borderRadius: BorderRadius.circular(14),
                      border: Border(
                        left: BorderSide(
                          color: topic.foreground.withOpacity(0.3),
                          width: 3,
                        ),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.question_mark_rounded,
                            size: 18,
                            color: topic.foreground.withOpacity(0.7),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            question,
                            style: const TextStyle(
                              height: 1.45,
                              color: Color(0xFF4D4857),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('Merksatz',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF6750A4),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'Religionserkennung bedeutet, kulturelle Formen neutral zu beschreiben – nicht zu behaupten, dass jede Person daran glaubt.',
              style: TextStyle(
                  color: Colors.white,
                  height: 1.42,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

List<String> _reflectionQuestions(String title) {
  final common = [
    'Was macht dieses Erlebnis für dich besonders?',
    'Welche Werte spürst du dabei?',
    'Könnte dies auch für andere Menschen Bedeutung haben?',
  ];
  return switch (title) {
    'Rituale' => [
        'Welche Wiederholungen gibt es in deinem Alltag, die dir wichtig sind?',
        'Hast du ein Ritual, das dir Halt gibt?',
        ...common,
      ],
    'Gemeinschaft' => [
        'In welcher Gruppe fühlst du dich besonders zugehörig?',
        'Was verbindet dich mit anderen Menschen in dieser Gruppe?',
        ...common,
      ],
    'Symbole' => [
        'Welcher Gegenstand hat für dich eine besondere Bedeutung?',
        'Was erinnert dich an wichtige Menschen oder Momente?',
        ...common,
      ],
    'Transzendenz' => [
        'Wann hast du zuletzt etwas erlebt, das dich staunen ließ?',
        'Gibt es Momente, in denen du das Gefühl hattest, Teil von etwas Größerem zu sein?',
        ...common,
      ],
    'Deutung' => [
        'Welche Geschichte oder welches Lied begleitet dich durchs Leben?',
        'Wie ordnest du schwierige Erfahrungen ein?',
        ...common,
      ],
    'Musik' => [
        'Welches Lied löst bei dir starke Emotionen aus?',
        'Hast du schon einmal ein Konzert erlebt, das dich berührt hat?',
        ...common,
      ],
    'Film & Kino' => [
        'Welcher Film hat dich zum Nachdenken gebracht?',
        'Welche Heldengeschichte inspiriert dich?',
        ...common,
      ],
    'Kunst & Museen' => [
        'Welches Kunstwerk hat dich beeindruckt?',
        'Kann Kunst spirituelle Erfahrungen vermitteln?',
        ...common,
      ],
    'Web & Social Media' => [
        'Welche digitale Gemeinschaft ist dir wichtig?',
        'Wie verändern soziale Medien dein Gefühl von Zugehörigkeit?',
        ...common,
      ],
    'Sport & Fanszenen' => [
        'Hast du beim Sport schon einmal kollektive Euphorie erlebt?',
        'Was verbindet dich mit anderen Fans?',
        ...common,
      ],
    'Mode & Stil' => [
        'Welches Kleidungsstück hat für dich eine besondere Bedeutung?',
        'Drückt dein Stil etwas über dich aus?',
        ...common,
      ],
    'Essen & Kulinarik' => [
        'Welches Essen erinnert dich an deine Familie oder Kindheit?',
        'Gibt es ein Festtagsessen, das dir besonders wichtig ist?',
        ...common,
      ],
    'Reisen & Orte' => [
        'Welcher Ort hat dich besonders beeindruckt?',
        'Hast du schon einmal an einem Ort gespürt, dass etwas Besonderes passiert?',
        ...common,
      ],
    'Natur & Jahreszeiten' => [
        'Welche Jahreszeit bedeutet dir am meisten?',
        'Wann hast du zuletzt die Natur bewusst wahrgenommen?',
        ...common,
      ],
    'Arbeit & Büro' => [
        'Gibt es Rituale in deiner Arbeit, die dir wichtig sind?',
        'Welche Kollegen bedeuten dir etwas?',
        ...common,
      ],
    'Schule & Universität' => [
        'Welcher Lehrer hat dich besonders geprägt?',
        'Welches Erlebnis in der Schule war für dich bedeutsam?',
        ...common,
      ],
    'Familie & Feiern' => [
        'Welche Familientradition ist dir am wichtigsten?',
        'Wie feierst du Geburtstage oder Feiertage?',
        ...common,
      ],
    'Technik & Geräte' => [
        'Kannst du dir vorstellen, einen Tag ohne Smartphone zu verbringen?',
        'Welche digitale Erinnerung ist dir besonders wichtig?',
        ...common,
      ],
    'Spiele & Gaming' => [
        'Welches Spiel hat dich in eine andere Welt eintauchen lassen?',
        'Spiele ihr gemeinsam mit Freunden oder Familie?',
        ...common,
      ],
    'Bücher & Literatur' => [
        'Welches Buch hat dich zum Nachdenken gebracht?',
        'Gibt es eine Geschichte, die dich begleitet?',
        ...common,
      ],
    'Architektur & Räume' => [
        'Welcher Raum gibt dir ein Gefühl von Geborgenheit?',
        'Kann ein Gebäude spirituell wirken?',
        ...common,
      ],
    _ => common,
  };
}

class _HistoryPage extends StatefulWidget {
  final _HistoryStore history;
  const _HistoryPage({required this.history});

  @override
  State<_HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<_HistoryPage> {
  @override
  void initState() {
    super.initState();
    widget.history.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.history.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.history.items;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Verlauf',
                    style:
                        TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              ),
              if (items.isNotEmpty)
                TextButton(
                  onPressed: widget.history.clear,
                  child: const Text('Leeren'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Column(
                children: [
                  Icon(Icons.history_rounded,
                      size: 48, color: Color(0xFFAAA5B3)),
                  SizedBox(height: 12),
                  Text('Noch keine Analysen',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  SizedBox(height: 4),
                  Text('Deine Anfragen werden hier gespeichert.',
                      style: TextStyle(color: Color(0xFF777381))),
                ],
              ),
            )
          else
            ...items.map((item) {
              final religious = item['religious'] == true;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: religious
                          ? const Color(0xFFE9DEF7)
                          : const Color(0xFFE6EDF0),
                      foregroundColor: religious
                          ? const Color(0xFF6750A4)
                          : const Color(0xFF507A84),
                      child: Icon(religious
                          ? Icons.auto_awesome_rounded
                          : Icons.lightbulb_outline_rounded),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item['input']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 3),
                          Text(item['answer']?.toString() ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Color(0xFF777381), height: 1.3)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  final _keyController = TextEditingController();
  bool _keySaved = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('gemini_api_key')?.trim();
    if (key == null || key.isEmpty) {
      // Kein hardcodierter API-Key. Nutzer muss eigenen Key in Optionen eingeben.
      if (!mounted) return;
      setState(() {
        _keySaved = false;
        _keyController.text = '';
      });
    } else {
      if (!mounted) return;
      setState(() {
        _keySaved = true;
        _keyController.text = key;
      });
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key);
    if (!mounted) return;
    setState(() => _keySaved = key.isNotEmpty);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(key.isEmpty
            ? 'API-Key wurde entfernt.'
            : 'API-Key wurde lokal gespeichert.'),
      ),
    );
  }

  Future<void> _testApi() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte zuerst einen API-Key eintragen.')),
      );
      return;
    }

    try {
      http.Response? result;
      for (final model in await _getAvailableFreeModels(key)) {
        result = await http.post(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
          ),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': key,
          },
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': 'Antworte nur mit: Gemini funktioniert.'},
                ],
              },
            ],
          }),
        );
        if (result.statusCode == 200) break;
      }

      if (!mounted) return;
      if (result?.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('gemini_api_key', key);
        if (!mounted) return;
        setState(() => _keySaved = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Verbindung erfolgreich. Kostenloses Gemini-Modell funktioniert.'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Test fehlgeschlagen: HTTP ${result?.statusCode}. Key oder API-Zugriff prüfen.',
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keine Verbindung zum Gemini-Service möglich.'),
        ),
      );
    }
  }

  void _showApiInstructions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Gemini API in der App',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                '1. Erstelle bei Google AI Studio einen API-Key.\n'
                '2. Trage ihn oben in „Gemini API“ ein.\n'
                '3. Tippe „Kostenloses Modell testen“.\n'
                '4. Sende danach im Analyse-Chat eine Frage.',
                style: TextStyle(height: 1.45),
              ),
              const SizedBox(height: 18),
              const Text('Terminal-Test',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF24212B),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const SelectableText(
                  'curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent" \\\n'
                  '  -H "Content-Type: application/json" \\\n'
                  '  -H "X-goog-api-key: DEIN_API_KEY" \\\n'
                  '  -X POST \\\n'
                  '  -d "{\\"contents\\":[{\\"parts\\":[{\\"text\\":\\"Explain how AI works in a few words\\"}]}]}"',
                  style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      height: 1.45,
                      fontSize: 12),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Hinweis: Teile deinen API-Key nie öffentlich und entferne veröffentlichte Keys in Google AI Studio.',
                style: TextStyle(
                    color: Color(0xFF9A5A46),
                    fontWeight: FontWeight.w600,
                    height: 1.35),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          const Text('Optionen',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9DEF7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.temple_hindu_outlined,
                      color: Color(0xFF6750A4), size: 30),
                ),
                const SizedBox(height: 14),
                const Text('Religion im Alltag',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                const Text(
                  'Eine App zum Entdecken sichtbarer und latenter religiöser Bezüge in Musik, Film und Alltag.',
                  style: TextStyle(
                      color: Color(0xFF777381), height: 1.42),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.key_rounded, color: Color(0xFF6750A4)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Gemini API',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _keySaved
                            ? const Color(0xFFE4EEDB)
                            : const Color(0xFFF0ECEF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _keySaved ? 'Gespeichert' : 'Fehlt',
                        style: TextStyle(
                          color: _keySaved
                              ? const Color(0xFF5D7847)
                              : const Color(0xFF777381),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _keyController,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    hintText: 'API-Key einfügen',
                    filled: true,
                    fillColor: const Color(0xFFF3F1F7),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _keyController.clear();
                          _saveKey();
                        },
                        child: const Text('Entfernen'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saveKey,
                        child: const Text('Speichern'),
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _testApi,
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: const Text('Kostenloses Modell testen'),
                  ),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => _showApiInstructions(context),
                  child: const Text('API-Anleitung anzeigen'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const _SettingTile(
            icon: Icons.person_outline_rounded,
            title: 'Made by Jojosstudio',
            subtitle: 'Projekt für Religion',
          ),
          const _SettingTile(
            icon: Icons.lock_outline_rounded,
            title: 'Datenschutz',
            subtitle: 'Verlauf wird nur lokal auf diesem Gerät gespeichert',
          ),
          const _SettingTile(
            icon: Icons.info_outline_rounded,
            title: 'Version',
            subtitle: '1.0.0',
          ),
        ],
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF6750A4)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: Color(0xFF777381), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
