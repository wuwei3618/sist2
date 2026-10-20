import GRDB
import SistCore

/// One database holds everything sist2 splits between the scan's index file and the separate
/// search index: with a single backend there is nothing to gain from keeping them apart, and
/// writing a document and its FTS row in the same transaction means the search index can never
/// be stale or need sist2's `dirty` flag.
///
/// The bulky parts live in their own tables (`content`, `thumbnail`) so that `document` rows stay
/// small: listing, sorting, facet counts and the per-file incremental check only read small rows.
enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE source (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    root TEXT NOT NULL UNIQUE,
                    options TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    lastScanAt DATETIME,
                    lastScanId INTEGER
                );

                -- One row per scan run. Its id is the "version" documents are stamped with, like
                -- sist2's version table.
                CREATE TABLE scan (
                    id INTEGER PRIMARY KEY,
                    sourceId INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    startedAt DATETIME NOT NULL,
                    finishedAt DATETIME,
                    status TEXT NOT NULL,
                    filesWalked INTEGER NOT NULL DEFAULT 0,
                    filesUnchanged INTEGER NOT NULL DEFAULT 0,
                    filesParsed INTEGER NOT NULL DEFAULT 0,
                    filesDeleted INTEGER NOT NULL DEFAULT 0,
                    errors INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE document (
                    id INTEGER PRIMARY KEY,
                    sourceId INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    -- Archive members point at their archive; deleting it deletes them
                    parentId INTEGER REFERENCES document(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    ext TEXT NOT NULL,
                    mime TEXT,
                    category TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime INTEGER NOT NULL,
                    title TEXT,
                    metadata TEXT,
                    checksum TEXT,
                    error TEXT,
                    thumbnailCount INTEGER NOT NULL DEFAULT 0,
                    -- The scan that last parsed the file
                    scanId INTEGER NOT NULL,
                    -- The last scan that found it on disk; rows a finished scan did not see are deleted
                    seenScanId INTEGER NOT NULL,
                    UNIQUE (sourceId, path)
                );
                CREATE INDEX document_parent ON document(parentId);
                CREATE INDEX document_mtime ON document(mtime);
                CREATE INDEX document_size ON document(size);
                CREATE INDEX document_category ON document(category, mime);
                CREATE INDEX document_seen ON document(sourceId, seenScanId);

                CREATE TABLE content (
                    documentId INTEGER PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
                    text TEXT NOT NULL
                );

                CREATE TABLE thumbnail (
                    documentId INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    num INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (documentId, num)
                ) WITHOUT ROWID;

                CREATE TABLE tag (
                    documentId INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    PRIMARY KEY (documentId, name)
                ) WITHOUT ROWID;
                CREATE INDEX tag_name ON tag(name);

                -- Holds the CJK-rewritten text (see SearchText), keyed by document id. Excerpts
                -- are cut from `content`, not from here.
                CREATE VIRTUAL TABLE document_fts USING fts5(
                    name, title, content, path,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                -- Same column weights as sist2: name 8, title 8, content 3, path 5
                INSERT INTO document_fts(document_fts, rank) VALUES ('rank', 'bm25(8.0, 8.0, 3.0, 5.0)');

                -- Also fires for rows removed by the cascades above
                CREATE TRIGGER document_fts_delete AFTER DELETE ON document BEGIN
                    DELETE FROM document_fts WHERE rowid = old.id;
                END;
                """)
        }

        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                -- The options of the last complete scan: when they change in ways that affect
                -- parsing, the next scan parses every file again
                ALTER TABLE source ADD COLUMN indexedOptions TEXT;

                -- Directory of files on disk (NULL for archive members): the folder tree, and
                -- deletion in scans limited to some directories
                ALTER TABLE document ADD COLUMN directory TEXT;
                UPDATE document SET directory = coalesce(nullif(rtrim(rtrim(path, replace(path, '/', '')), '/'), ''), '/')
                WHERE parentId IS NULL;
                CREATE INDEX document_directory ON document(sourceId, parentId, directory, size);

                -- Every folder holding files, with recursive counts, rebuilt at the end of each
                -- scan (sist2's path_index)
                CREATE TABLE folder (
                    sourceId INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    parent TEXT,
                    name TEXT NOT NULL,
                    count INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    PRIMARY KEY (sourceId, path)
                ) WITHOUT ROWID;
                CREATE INDEX folder_parent ON folder(sourceId, parent);
                """)
            for row in try Row.fetchAll(db, sql: "SELECT id, root FROM source") {
                try CatalogWriter.rebuildFolders(db, sourceId: row["id"], root: row["root"])
            }
        }

        migrator.registerMigration("v3") { db in
            // The FTS table kept its own copy of the rewritten text, which nothing reads: excerpts
            // come from `content`. Contentless, it takes about a third of the space. Deleting rows
            // from a contentless table needs SQLite 3.43 (macOS 14); older ones keep the table.
            // v4 fills it.
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? ""
            guard supportsContentlessDelete(version: version) else { return }
            try db.execute(sql: """
                DROP TABLE document_fts;
                CREATE VIRTUAL TABLE document_fts USING fts5(
                    name, title, content, path,
                    tokenize = 'unicode61 remove_diacritics 2',
                    content = '', contentless_delete = 1
                );
                INSERT INTO document_fts(document_fts, rank) VALUES ('rank', 'bm25(8.0, 8.0, 3.0, 5.0)');
                """)
        }

        migrator.registerMigration("v4") { db in
            // CJK text is indexed one character per token instead of as bigrams (see SearchText),
            // and long texts are stored compressed (see ContentCodec): every row is rewritten
            let definition = try String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE name = 'document_fts'") ?? ""
            try db.execute(sql: "DROP TABLE document_fts")
            try db.execute(sql: definition)
            try db.execute(sql: "INSERT INTO document_fts(document_fts, rank) VALUES ('rank', 'bm25(8.0, 8.0, 3.0, 5.0)')")

            let insert = try db.makeStatement(
                sql: "INSERT INTO document_fts (rowid, name, title, content, path) VALUES (?, ?, ?, ?, ?)")
            let compress = try db.makeStatement(sql: "UPDATE content SET text = ? WHERE documentId = ?")
            var lastId: Int64 = 0
            while true {
                // In batches: the content table is updated along the way
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.path, d.name, d.title, s.root, c.text
                    FROM document d JOIN source s ON s.id = d.sourceId LEFT JOIN content c ON c.documentId = d.id
                    WHERE d.id > ? ORDER BY d.id LIMIT 1000
                    """, arguments: [lastId])
                guard let last = rows.last else { break }
                lastId = last["id"]
                for row in rows {
                    let id: Int64 = row["id"]
                    let content = ContentCodec.decode(row["text"])
                    if let content, case .string = (row["text"] as DatabaseValue).storage,
                       let compressed = ContentCodec.compress(content) {
                        try compress.execute(arguments: [compressed, id])
                    }
                    let document = ParsedDocument(path: row["path"], name: row["name"], ext: "", mime: nil,
                                                  size: 0, mtime: 0, title: row["title"], content: content)
                    let text = SearchText.indexedText(for: document, root: row["root"])
                    try insert.execute(arguments: [id, text.name, text.title, text.content, text.path])
                }
            }
        }

        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                -- Searches the user saved: the query and filters as the app encodes them
                CREATE TABLE saved_search (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    state TEXT NOT NULL,
                    createdAt DATETIME NOT NULL
                );

                -- The terms of the full-text index with their document counts, for spelling
                -- suggestions (sist2 uses spellfix, which the system SQLite does not have)
                CREATE VIRTUAL TABLE document_vocab USING fts5vocab(document_fts, 'row');
                """)
        }

        return migrator
    }

    static func supportsContentlessDelete(version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (3, 43)
    }
}
