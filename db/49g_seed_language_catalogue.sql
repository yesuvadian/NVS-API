-- Seed the initial platform label catalogue used by Super Admin language packs.
-- This mirrors the app's existing EN/TA "Members" navigation label and gives
-- a clean installation a real translatable row from its first language pack.
INSERT INTO platform.translation_text
    (text_id, module_code, text_type, english_text, status)
VALUES
    ('nav_members', 'MEMBER', 'LABEL', 'Members', 'ACTIVE')
ON CONFLICT (text_id) DO UPDATE
    SET module_code = EXCLUDED.module_code,
        text_type = EXCLUDED.text_type,
        english_text = EXCLUDED.english_text,
        status = EXCLUDED.status,
        updated_at = now();

DO $$
DECLARE
    v_version integer;
    v_latest_published integer;
BEGIN
    SELECT max(version_no)
      INTO v_latest_published
      FROM platform.language_pack
     WHERE language_code = 'ta' AND status = 'PUBLISHED';

    IF v_latest_published IS NOT NULL AND EXISTS (
        SELECT 1
          FROM platform.translation_entry
         WHERE language_code = 'ta'
           AND version_no = v_latest_published
           AND text_id = 'nav_members'
           AND translated_text = 'உறுப்பினர்கள்'
           AND status = 'APPROVED'
    ) THEN
        RETURN;
    END IF;

    SELECT coalesce(max(version_no), 0) + 1
      INTO v_version
      FROM platform.language_pack
     WHERE language_code = 'ta';

    INSERT INTO platform.language_pack
        (language_code, version_no, status)
    VALUES ('ta', v_version, 'DRAFT');

    IF v_latest_published IS NOT NULL THEN
        INSERT INTO platform.translation_entry
            (language_code, version_no, text_id, translated_text, status)
        SELECT 'ta', v_version, entry.text_id, entry.translated_text, entry.status
          FROM platform.translation_entry AS entry
         WHERE entry.language_code = 'ta'
           AND entry.version_no = v_latest_published
        ON CONFLICT (language_code, version_no, text_id) DO NOTHING;
    END IF;

    INSERT INTO platform.translation_entry
        (language_code, version_no, text_id, translated_text, status)
    VALUES ('ta', v_version, 'nav_members', 'உறுப்பினர்கள்', 'APPROVED')
    ON CONFLICT (language_code, version_no, text_id) DO UPDATE
        SET translated_text = EXCLUDED.translated_text,
            status = EXCLUDED.status;

    PERFORM platform.publish_translation_pack('ta', v_version, NULL);
END
$$;
