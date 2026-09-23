//  Migrations — DDL миграции `v1-slice1`, C-010 (MEE-18) v7 §3, §4.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  DDL переписан из §3 контракта ДОСЛОВНО (постановка МЕЕ-324, п. 1). Правка
//  выпущенной миграции запрещена контрактом (§4) — этот файл после первого
//  слияния меняется только НОВОЙ миграцией с новым идентификатором, никогда
//  правкой строки `"v1-slice1"`.
//
//  `eraseDatabaseOnSchemaChange` (К5, §4) в этом файле не встречается ни разу —
//  сборке для пользователя он запрещён контрактом; тестовый путь при нужде
//  задаёт его в `StorageTests`, не здесь.

import GRDB

enum StorageMigrations {

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-slice1") { db in
            try db.execute(sql: schemaSQL)
        }
        return migrator
    }

    /// Список из четырёх — таблицы, индексы, триггеры (К3): использован тестами
    /// через Ш7 для сверки состава `sqlite_master`, а не только миграцией.
    static let tableNames = [
        "persons", "person_emails", "person_name_forms", "meetings", "meeting_sources",
        "attendees", "recordings", "transcripts", "segments", "speaker_profiles",
        "jobs", "connectors", "meeting_outputs", "app_settings",
    ]

    static let virtualTableNames = ["segments_fts"]

    static let indexNames = [
        "idx_persons_me", "idx_person_emails_person", "idx_person_name_forms_form",
        "idx_meetings_dedup", "idx_meetings_start", "idx_meeting_sources_meeting",
        "idx_recordings_meeting", "idx_transcripts_recording", "idx_segments_transcript",
        "idx_segments_person", "idx_jobs_claim", "idx_jobs_dedup", "idx_meeting_outputs_meeting",
    ]

    static let triggerNames = ["segments_fts_ai", "segments_fts_ad", "segments_fts_au"]

    static let schemaSQL = """
    CREATE TABLE persons (
        id            TEXT PRIMARY KEY NOT NULL,
        display_name  TEXT NOT NULL,
        is_me         INTEGER NOT NULL DEFAULT 0,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX idx_persons_me ON persons(is_me) WHERE is_me = 1;

    CREATE TABLE person_emails (
        email     TEXT PRIMARY KEY NOT NULL,
        person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_person_emails_person ON person_emails(person_id);

    CREATE TABLE person_name_forms (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
        form      TEXT NOT NULL,
        kind      TEXT NOT NULL CHECK (kind IN
                    ('full','first','last','translit','diminutive','user_added')),
        UNIQUE (person_id, form, kind)
    );
    CREATE INDEX idx_person_name_forms_form ON person_name_forms(form);

    CREATE TABLE meetings (
        id                    TEXT PRIMARY KEY NOT NULL,
        title                 TEXT NOT NULL,
        start_at              INTEGER NOT NULL,
        end_at                INTEGER NOT NULL,
        time_zone             TEXT NOT NULL,
        is_all_day            INTEGER NOT NULL,
        is_cancelled          INTEGER NOT NULL,
        provider              TEXT,
        join_url              TEXT,
        conference_meeting_id TEXT,
        conference_passcode   TEXT,
        organizer_person_id   TEXT REFERENCES persons(id) ON DELETE SET NULL,
        location              TEXT,
        body_text             TEXT,
        dedup_key             TEXT,
        status                TEXT NOT NULL CHECK (status IN
                                ('scheduled','armed','awaitingSignal','recording',
                                 'stopping','processing','ready','failed','skipped')),
        last_modified         INTEGER NOT NULL,
        created_at            INTEGER NOT NULL,
        updated_at            INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX idx_meetings_dedup ON meetings(dedup_key) WHERE dedup_key IS NOT NULL;
    CREATE INDEX idx_meetings_start ON meetings(start_at);

    CREATE TABLE meeting_sources (
        source_connector_id TEXT NOT NULL,
        external_id         TEXT NOT NULL,
        meeting_id          TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        ical_uid            TEXT,
        last_modified       INTEGER NOT NULL,
        PRIMARY KEY (source_connector_id, external_id)
    );
    CREATE INDEX idx_meeting_sources_meeting ON meeting_sources(meeting_id);

    CREATE TABLE attendees (
        meeting_id      TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        person_id       TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
        response_status TEXT NOT NULL CHECK (response_status IN
                          ('accepted','declined','tentative','needsAction','unknown')),
        is_optional     INTEGER NOT NULL,
        PRIMARY KEY (meeting_id, person_id)
    );

    CREATE TABLE recordings (
        id             TEXT PRIMARY KEY NOT NULL,
        meeting_id     TEXT REFERENCES meetings(id) ON DELETE SET NULL,
        directory_name TEXT NOT NULL UNIQUE,
        started_at     INTEGER NOT NULL,
        ended_at       INTEGER,
        manifest_json  TEXT NOT NULL,
        is_finalized   INTEGER NOT NULL,
        status         TEXT NOT NULL CHECK (status IN
                         ('recording','stopping','finalized','failed')),
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL
    );
    CREATE INDEX idx_recordings_meeting ON recordings(meeting_id);

    CREATE TABLE transcripts (
        id            TEXT PRIMARY KEY NOT NULL,
        recording_id  TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        file_index    INTEGER NOT NULL,
        engine        TEXT NOT NULL,
        model_version TEXT NOT NULL,
        language      TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        UNIQUE (recording_id, file_index)
    );
    CREATE INDEX idx_transcripts_recording ON transcripts(recording_id, created_at DESC);

    CREATE TABLE segments (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        transcript_id      TEXT NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
        start_ms           INTEGER NOT NULL,
        end_ms             INTEGER NOT NULL CHECK (end_ms > start_ms),
        channel            TEXT NOT NULL CHECK (channel IN ('mic','system')),
        cluster            INTEGER,
        person_id          TEXT REFERENCES persons(id) ON DELETE SET NULL,
        speaker_confidence REAL CHECK (speaker_confidence IS NULL OR (speaker_confidence BETWEEN 0 AND 1)),
        attribution_source TEXT CHECK (attribution_source IN
                             ('micChannel','voiceProfile','oneOnOne',
                              'textualHint','nameDictionary','user')),
        text               TEXT NOT NULL,
        text_original      TEXT,
        text_confidence    REAL CHECK (text_confidence IS NULL OR (text_confidence BETWEEN 0 AND 1)),
        words_json         TEXT NOT NULL,
        is_user_edited     INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_segments_transcript ON segments(transcript_id, start_ms);
    CREATE INDEX idx_segments_person ON segments(person_id);

    CREATE VIRTUAL TABLE segments_fts USING fts5(
        text,
        content='segments',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER segments_fts_ai AFTER INSERT ON segments BEGIN
        INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER segments_fts_ad AFTER DELETE ON segments BEGIN
        INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TRIGGER segments_fts_au AFTER UPDATE OF text ON segments BEGIN
        INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
    END;

    CREATE TABLE speaker_profiles (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        person_id     TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
        embedding     BLOB NOT NULL,
        embedding_dim INTEGER NOT NULL,
        model_version TEXT NOT NULL,
        sample_count  INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        UNIQUE (person_id, model_version)
    );

    CREATE TABLE jobs (
        id                   TEXT PRIMARY KEY NOT NULL,
        type                 TEXT NOT NULL CHECK (type IN
                               ('transcode','transcribe','diarize','attribute','summarize')),
        payload_json         TEXT NOT NULL,
        status               TEXT NOT NULL CHECK (status IN
                               ('pending','running','succeeded','failed','cancelled')),
        priority             INTEGER NOT NULL,
        attempts             INTEGER NOT NULL DEFAULT 0,
        max_attempts         INTEGER NOT NULL,
        run_after            INTEGER NOT NULL,
        requires_ac_power    INTEGER NOT NULL DEFAULT 0,
        forbid_while_recording INTEGER NOT NULL DEFAULT 0,
        max_thermal_pressure TEXT NOT NULL CHECK (max_thermal_pressure IN
                               ('nominal','fair','serious','critical')),
        requires_profile_ready TEXT,
        dedup_key            TEXT,
        lease_expires_at     INTEGER,
        attempt_started_at   INTEGER,
        last_error           TEXT,
        created_at           INTEGER NOT NULL,
        updated_at           INTEGER NOT NULL
    );
    CREATE INDEX idx_jobs_claim ON jobs(status, priority DESC, run_after);
    CREATE UNIQUE INDEX idx_jobs_dedup ON jobs(dedup_key)
        WHERE dedup_key IS NOT NULL AND status IN ('pending','running');

    CREATE TABLE connectors (
        id                         TEXT PRIMARY KEY NOT NULL,
        type                       TEXT NOT NULL CHECK (type IN ('eventkit','stdio')),
        plugin_id                  TEXT,
        settings_json              TEXT NOT NULL,
        keychain_namespace         TEXT NOT NULL,
        selected_calendar_ids_json TEXT NOT NULL,
        is_enabled                 INTEGER NOT NULL DEFAULT 1,
        last_sync_at               INTEGER,
        cursor                     TEXT,
        last_error                 TEXT
    );

    CREATE TABLE meeting_outputs (
        id              TEXT PRIMARY KEY NOT NULL,
        meeting_id      TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        kind            TEXT NOT NULL CHECK (kind IN
                          ('summary','decisions','action_items','open_questions')),
        engine          TEXT NOT NULL,
        model_version   TEXT NOT NULL,
        prompt_version  TEXT NOT NULL,
        content_md      TEXT NOT NULL,
        structured_json TEXT,
        created_at      INTEGER NOT NULL,
        is_user_edited  INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_meeting_outputs_meeting ON meeting_outputs(meeting_id, kind, created_at DESC);

    CREATE TABLE app_settings (
        key   TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );
    """
}
