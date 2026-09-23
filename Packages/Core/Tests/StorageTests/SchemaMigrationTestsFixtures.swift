//  SchemaMigrationTests — ожидаемые значения К3 (независимая транскрипция C-010 v7 §3),
//  разведены по объёму (`type_body_length`) с тестовыми функциями, не по смыслу.
//
//  Владелец: DEV-2.

extension SchemaMigrationTests {

    // MARK: - Ожидаемые значения (независимая транскрипция C-010 v7 §3)

    struct ExpectedColumn {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?

        init(_ name: String, _ type: String, notNull: Bool = false, defaultValue: String? = nil) {
            self.name = name
            self.type = type
            self.notNull = notNull
            self.defaultValue = defaultValue
        }
    }

    static let expectedTables = [
        "persons", "person_emails", "person_name_forms", "meetings", "meeting_sources",
        "attendees", "recordings", "transcripts", "segments", "speaker_profiles",
        "jobs", "connectors", "meeting_outputs", "app_settings"
    ]

    /// Фрагмент `WHERE` для `sqlite_master`: снимает то, что не входит в
    /// четырнадцать таблиц DDL §3, но реально существует в файле —
    /// `grdb_migrations` (таблица механизма миграций GRDB) и теневые таблицы
    /// FTS5, которые SQLite заводит сам для `segments_fts` (сама виртуальная
    /// таблица и её тени `_config`/`_data`/`_docsize`/`_idx` — все с одним
    /// префиксом имени, ловятся одним `LIKE`).
    static let ownTablesFilterSQL = """
        name NOT LIKE 'sqlite_%' AND name NOT LIKE 'segments_fts%' AND name <> 'grdb_migrations'
        """

    static let expectedIndexes = [
        "idx_persons_me", "idx_person_emails_person", "idx_person_name_forms_form",
        "idx_meetings_dedup", "idx_meetings_start", "idx_meeting_sources_meeting",
        "idx_recordings_meeting", "idx_transcripts_recording", "idx_segments_transcript",
        "idx_segments_person", "idx_jobs_claim", "idx_jobs_dedup", "idx_meeting_outputs_meeting"
    ]

    static let expectedUniqueIndexes = ["idx_persons_me", "idx_meetings_dedup", "idx_jobs_dedup"]

    static let expectedTriggers = ["segments_fts_ai", "segments_fts_ad", "segments_fts_au"]

    static let expectedColumns: [(String, [ExpectedColumn])] = [
        ("persons", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("display_name", "TEXT", notNull: true),
            ExpectedColumn("is_me", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true)
        ]),
        ("person_emails", [
            ExpectedColumn("email", "TEXT", notNull: true),
            ExpectedColumn("person_id", "TEXT", notNull: true)
        ]),
        ("person_name_forms", [
            ExpectedColumn("id", "INTEGER"),
            ExpectedColumn("person_id", "TEXT", notNull: true),
            ExpectedColumn("form", "TEXT", notNull: true),
            ExpectedColumn("kind", "TEXT", notNull: true)
        ]),
        ("meetings", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("title", "TEXT", notNull: true),
            ExpectedColumn("start_at", "INTEGER", notNull: true),
            ExpectedColumn("end_at", "INTEGER", notNull: true),
            ExpectedColumn("time_zone", "TEXT", notNull: true),
            ExpectedColumn("is_all_day", "INTEGER", notNull: true),
            ExpectedColumn("is_cancelled", "INTEGER", notNull: true),
            ExpectedColumn("provider", "TEXT"),
            ExpectedColumn("join_url", "TEXT"),
            ExpectedColumn("conference_meeting_id", "TEXT"),
            ExpectedColumn("conference_passcode", "TEXT"),
            ExpectedColumn("organizer_person_id", "TEXT"),
            ExpectedColumn("location", "TEXT"),
            ExpectedColumn("body_text", "TEXT"),
            ExpectedColumn("dedup_key", "TEXT"),
            ExpectedColumn("status", "TEXT", notNull: true),
            ExpectedColumn("last_modified", "INTEGER", notNull: true),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true)
        ]),
        ("meeting_sources", [
            ExpectedColumn("source_connector_id", "TEXT", notNull: true),
            ExpectedColumn("external_id", "TEXT", notNull: true),
            ExpectedColumn("meeting_id", "TEXT", notNull: true),
            ExpectedColumn("ical_uid", "TEXT"),
            ExpectedColumn("last_modified", "INTEGER", notNull: true)
        ]),
        ("attendees", [
            ExpectedColumn("meeting_id", "TEXT", notNull: true),
            ExpectedColumn("person_id", "TEXT", notNull: true),
            ExpectedColumn("response_status", "TEXT", notNull: true),
            ExpectedColumn("is_optional", "INTEGER", notNull: true)
        ]),
        ("recordings", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("meeting_id", "TEXT"),
            ExpectedColumn("directory_name", "TEXT", notNull: true),
            ExpectedColumn("started_at", "INTEGER", notNull: true),
            ExpectedColumn("ended_at", "INTEGER"),
            ExpectedColumn("manifest_json", "TEXT", notNull: true),
            ExpectedColumn("is_finalized", "INTEGER", notNull: true),
            ExpectedColumn("status", "TEXT", notNull: true),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true)
        ]),
        ("transcripts", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("recording_id", "TEXT", notNull: true),
            ExpectedColumn("file_index", "INTEGER", notNull: true),
            ExpectedColumn("engine", "TEXT", notNull: true),
            ExpectedColumn("model_version", "TEXT", notNull: true),
            ExpectedColumn("language", "TEXT", notNull: true),
            ExpectedColumn("created_at", "INTEGER", notNull: true)
        ]),
        ("segments", [
            ExpectedColumn("id", "INTEGER"),
            ExpectedColumn("transcript_id", "TEXT", notNull: true),
            ExpectedColumn("start_ms", "INTEGER", notNull: true),
            ExpectedColumn("end_ms", "INTEGER", notNull: true),
            ExpectedColumn("channel", "TEXT", notNull: true),
            ExpectedColumn("cluster", "INTEGER"),
            ExpectedColumn("person_id", "TEXT"),
            ExpectedColumn("speaker_confidence", "REAL"),
            ExpectedColumn("attribution_source", "TEXT"),
            ExpectedColumn("text", "TEXT", notNull: true),
            ExpectedColumn("text_original", "TEXT"),
            ExpectedColumn("text_confidence", "REAL"),
            ExpectedColumn("words_json", "TEXT", notNull: true),
            ExpectedColumn("is_user_edited", "INTEGER", notNull: true, defaultValue: "0")
        ]),
        ("speaker_profiles", [
            ExpectedColumn("id", "INTEGER"),
            ExpectedColumn("person_id", "TEXT", notNull: true),
            ExpectedColumn("embedding", "BLOB", notNull: true),
            ExpectedColumn("embedding_dim", "INTEGER", notNull: true),
            ExpectedColumn("model_version", "TEXT", notNull: true),
            ExpectedColumn("sample_count", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true)
        ]),
        ("jobs", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("type", "TEXT", notNull: true),
            ExpectedColumn("payload_json", "TEXT", notNull: true),
            ExpectedColumn("status", "TEXT", notNull: true),
            ExpectedColumn("priority", "INTEGER", notNull: true),
            ExpectedColumn("attempts", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("max_attempts", "INTEGER", notNull: true),
            ExpectedColumn("run_after", "INTEGER", notNull: true),
            ExpectedColumn("requires_ac_power", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("forbid_while_recording", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("max_thermal_pressure", "TEXT", notNull: true),
            ExpectedColumn("requires_profile_ready", "TEXT"),
            ExpectedColumn("dedup_key", "TEXT"),
            ExpectedColumn("lease_expires_at", "INTEGER"),
            ExpectedColumn("attempt_started_at", "INTEGER"),
            ExpectedColumn("last_error", "TEXT"),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true)
        ]),
        ("connectors", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("type", "TEXT", notNull: true),
            ExpectedColumn("plugin_id", "TEXT"),
            ExpectedColumn("settings_json", "TEXT", notNull: true),
            ExpectedColumn("keychain_namespace", "TEXT", notNull: true),
            ExpectedColumn("selected_calendar_ids_json", "TEXT", notNull: true),
            ExpectedColumn("is_enabled", "INTEGER", notNull: true, defaultValue: "1"),
            ExpectedColumn("last_sync_at", "INTEGER"),
            ExpectedColumn("cursor", "TEXT"),
            ExpectedColumn("last_error", "TEXT")
        ]),
        ("meeting_outputs", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("meeting_id", "TEXT", notNull: true),
            ExpectedColumn("kind", "TEXT", notNull: true),
            ExpectedColumn("engine", "TEXT", notNull: true),
            ExpectedColumn("model_version", "TEXT", notNull: true),
            ExpectedColumn("prompt_version", "TEXT", notNull: true),
            ExpectedColumn("content_md", "TEXT", notNull: true),
            ExpectedColumn("structured_json", "TEXT"),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("is_user_edited", "INTEGER", notNull: true, defaultValue: "0")
        ]),
        ("app_settings", [
            ExpectedColumn("key", "TEXT", notNull: true),
            ExpectedColumn("value", "TEXT", notNull: true)
        ])
    ]
}
