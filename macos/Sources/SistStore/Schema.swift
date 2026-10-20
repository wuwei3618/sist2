import GRDB

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

        return migrator
    }
}
