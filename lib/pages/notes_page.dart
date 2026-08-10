class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {

  late final QuillController _controller;

  @override
  void initState() {
    super.initState();

    _controller = QuillController.basic();
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(
        title: const Text("Notes"),
      ),

      body: Column(

        children: [

          QuillSimpleToolbar(
            controller: _controller,
            config: const QuillSimpleToolbarConfig(),
          ),

          Expanded(

            child: QuillEditor.basic(

              controller: _controller,

              config: const QuillEditorConfig(),

            ),

          )

        ],

      ),

    );

  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}