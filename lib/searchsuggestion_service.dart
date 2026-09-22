import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

final words = [
    'aadhaar',
    'passport',
    'pan card',
    'driving licence',
    'cheque',
    'paytm',
    'phonepe',
    'electricity bill',
    'credit card',
    'debit card'
];

class SearchSuggestionService{
    late final Database db;
    Future<void> initialize() async{
        final databasepath=await getDatabasesPath();
        final path=join(databasepath,"searchsuggestion.db",);
        db=await openDatabase(
            path, version:1,
            onCreate: (Database db, int version) async{
                await db.execute("""
                    CREATE TABLE search_suggestion(
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        word TEXT UNIQUE,
                        time INTEGER
                    )
                """);
                for(final word in words){
                    await db.execute(
                        "INSERT INTO search_suggestion (word, time) VALUES (?,?) ON CONFLICT(word) DO UPDATE SET time=excluded.time",
                        [word, DateTime.now().millisecondsSinceEpoch(),]
                    );
                }
            }
        );
    }

    Future<void> update(String word) async{
        await db.execute("""
            INSERT INTO search_suggestion (word,time) VALUES (?,?) ON CONFLICT(word) DO UPDATE SET time=excluded.time""",
            [word.toLowerCase(),DateTime.now().millisecondsSinceEpoch(),]
        );
    }

    Future<List<String>> query(String prefix) async{
        List<Map<String,dynamic>> results=await db.rawQuery("""
            SELECT word FROM search_suggestion WHERE word LIKE ? ORDER BY time DESC LIMIT 5""",
            [prefix.toLowerCase()+"%",]
        );
        List<String> suggestions=[];
        for (final res in results){
            suggestions.add(res["word"]);
        }
        return suggestions;
    }

    Future<void> clear() async{
        await db.delete('search_suggestion');
    }
}