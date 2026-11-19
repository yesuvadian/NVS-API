-- =============================================================================
-- CFMS / NVS  -  47  Error codes for the concurrency controls (script 17 and
--                   the double-save / concurrent-save fixes in 30-38)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run. Tamil text is included; the API falls back to
-- English for a language without a message.
-- =============================================================================

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-SYS-1006','IDEMPOTENCY_KEY_REQUIRED','SYS','VALIDATION','ERROR',428,false,false,'This request needs an Idempotency-Key header.','Send a new unique key each time the form is opened, and the same key when retrying.'),
 ('CFMS-SYS-1007','IDEMPOTENCY_KEY_INVALID','SYS','VALIDATION','ERROR',400,false,false,'The Idempotency-Key is not valid.','Use 8 to 100 letters, digits or the characters _ . : -'),
 ('CFMS-SYS-1008','ROW_VERSION_REQUIRED','SYS','VALIDATION','ERROR',428,false,false,'Send the version of the record you opened (X-Expected-Row-Version).','Reload the record and save again.'),
 ('CFMS-SYS-5006','IDEMPOTENCY_KEY_REUSED','SYS','CONFLICT','ERROR',409,false,false,'This Idempotency-Key was already used for a different request.','Use a new key for a new transaction.'),
 ('CFMS-SYS-5007','IDEMPOTENCY_REQUEST_IN_PROGRESS','SYS','CONFLICT','WARNING',409,true,false,'The same request is still being processed.','Wait a moment and try again with the same key.'),
 ('CFMS-SYS-5008','JOB_ALREADY_RUNNING','SYS','CONFLICT','WARNING',409,true,false,'This job is already running for the organisation.','Wait for the running job to finish.'),
 ('CFMS-MEM-5001','DUPLICATE_MEMBER','MEM','CONFLICT','ERROR',409,false,false,'A member with the same mobile number, or the same name and date of birth, already exists.','Open the existing member, or confirm with a reason that this is a different person.'),
 ('CFMS-LOAN-5017','LOAN_APPLICATION_ALREADY_OPEN','LOAN','CONFLICT','ERROR',409,false,false,'The member already has an open application for this loan type.','Continue the open application, or withdraw it first.'),
 ('CFMS-LOAN-2034','MAX_CONCURRENT_LOANS_REACHED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The member has reached the maximum number of approved or running loans.','Close or settle a running loan first.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('IDEMPOTENCY_KEY_REQUIRED','இந்தக் கோரிக்கைக்கு Idempotency-Key தலைப்பு தேவை.'),
 ('IDEMPOTENCY_KEY_INVALID','Idempotency-Key சரியானதல்ல.'),
 ('ROW_VERSION_REQUIRED','நீங்கள் திறந்த பதிவின் பதிப்பை அனுப்பவும் (X-Expected-Row-Version).'),
 ('IDEMPOTENCY_KEY_REUSED','இந்த Idempotency-Key ஏற்கனவே வேறொரு கோரிக்கைக்குப் பயன்படுத்தப்பட்டுள்ளது.'),
 ('IDEMPOTENCY_REQUEST_IN_PROGRESS','இதே கோரிக்கை இன்னும் செயலாக்கத்தில் உள்ளது.'),
 ('JOB_ALREADY_RUNNING','இந்தப் பணி இந்த நிறுவனத்திற்கு ஏற்கனவே இயங்கிக்கொண்டிருக்கிறது.'),
 ('DUPLICATE_MEMBER','அதே கைபேசி எண் அல்லது அதே பெயரும் பிறந்த தேதியும் கொண்ட உறுப்பினர் ஏற்கனவே உள்ளார்.'),
 ('LOAN_APPLICATION_ALREADY_OPEN','இந்தக் கடன் வகைக்கு உறுப்பினருக்கு ஏற்கனவே திறந்த விண்ணப்பம் உள்ளது.'),
 ('MAX_CONCURRENT_LOANS_REACHED','உறுப்பினர் அங்கீகரிக்கப்பட்ட அல்லது நடப்பிலுள்ள கடன்களின் அதிகபட்ச எண்ணிக்கையை அடைந்துவிட்டார்.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;

-- Named constraints that carry a business meaning
INSERT INTO platform.constraint_error_map (constraint_name, error_code, note) VALUES
 ('idempotency_request_key_uq','CFMS-SYS-5007','Same Idempotency-Key at the same moment'),
 ('cash_receipt_idem_uq','CFMS-ACC-5004','Resubmitting the same receipt'),
 ('payment_voucher_idem_uq','CFMS-ACC-5004','Resubmitting the same payment voucher'),
 ('cooling_off_override_pending_uq','CFMS-LOAN-5008',NULL),
 ('loan_waiver_pending_uq','CFMS-LOAN-5007',NULL),
 ('loan_restructure_pending_uq','CFMS-LOAN-5014',NULL),
 ('loan_write_off_open_uq','CFMS-LOAN-5009',NULL),
 ('loan_charge_late_fee_once_uq','CFMS-SYS-5008','Overlapping daily loan job runs')
ON CONFLICT (constraint_name) DO UPDATE SET error_code = EXCLUDED.error_code, note = EXCLUDED.note;
