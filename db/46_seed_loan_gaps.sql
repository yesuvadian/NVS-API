-- =============================================================================
-- CFMS / NVS  -  46  Error codes, settings, jobs and notification templates for
--                   the loan module additions (scripts 16 and 33-37)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run. Tamil text is included; the API falls back to
-- English for a language without a message.
-- =============================================================================

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-REPAY-2002','REPAYMENT_CLEARS_LOAN','REPAY','BUSINESS_RULE','ERROR',422,false,false,'The amount clears the whole loan.','Prepare an early settlement quote instead.'),
 ('CFMS-LOAN-1005','SCHEDULE_NEEDS_INSTALMENTS','LOAN','VALIDATION','ERROR',422,false,false,'A new schedule needs at least one instalment.','Check the tenure and dates.'),
 ('CFMS-SYS-4010','USER_NOT_FOUND','SYS','NOT_FOUND','ERROR',404,false,false,'The user was not found or is not active.','Choose an active user.'),
 ('CFMS-LOAN-4006','RECOVERY_CASE_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The open recovery case was not found.','Refresh the recovery cases.'),
 ('CFMS-LOAN-1006','RECOVERY_OUTCOME_REQUIRED','LOAN','VALIDATION','ERROR',422,false,false,'Record the outcome of the contact.','Enter what happened and try again.'),
 ('CFMS-LOAN-1007','PROMISE_DATE_PAST','LOAN','VALIDATION','ERROR',422,false,false,'The promised payment date cannot be in the past.','Enter today or a later date.'),
 ('CFMS-LOAN-1008','INVALID_RECOVERY_STATUS','LOAN','VALIDATION','ERROR',422,false,false,'This recovery status cannot be set by hand.','Choose another status.'),
 ('CFMS-LOAN-1009','INVALID_WAIVER_AMOUNT','LOAN','VALIDATION','ERROR',422,false,false,'The waiver amount is not valid.','Enter an amount up to the open amount.'),
 ('CFMS-LOAN-2011','WAIVER_NOT_ALLOWED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'This waiver is not allowed.','Check the loan type rules.'),
 ('CFMS-LOAN-2012','WAIVER_TARGET_NOT_OPEN','LOAN','BUSINESS_RULE','ERROR',422,false,false,'There is nothing open to waive.','Refresh the loan charges.'),
 ('CFMS-LOAN-5007','WAIVER_ALREADY_PENDING','LOAN','CONFLICT','ERROR',409,false,false,'A waiver for this item is already waiting for approval.','Wait for the decision on the first request.'),
 ('CFMS-LOAN-4007','WAIVER_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The waiver request was not found.','Refresh the waivers.'),
 ('CFMS-LOAN-2013','OVERRIDE_NOT_NEEDED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The member is not in a cooling-off period or restricted.','No override is needed.'),
 ('CFMS-LOAN-5008','OVERRIDE_ALREADY_PENDING','LOAN','CONFLICT','ERROR',409,false,false,'An override for this member is already waiting for a decision.','Wait for the decision on the first request.'),
 ('CFMS-LOAN-4008','OVERRIDE_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The override request was not found.','Refresh the requests.'),
 ('CFMS-LOAN-2014','OPEN_DEFAULT_EXISTS','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The member still has an unsettled defaulted loan.','Settle the defaulted loan first.'),
 ('CFMS-LOAN-2015','WRITE_OFF_NOT_ALLOWED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'This loan cannot be written off.','Check the loan status and balance.'),
 ('CFMS-LOAN-5009','WRITE_OFF_ALREADY_PROPOSED','LOAN','CONFLICT','ERROR',409,false,false,'A write-off for this loan is already waiting for a decision.','Wait for the decision on the proposal.'),
 ('CFMS-LOAN-4009','WRITE_OFF_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The write-off proposal was not found.','Refresh the proposals.'),
 ('CFMS-LOAN-5010','WRITE_OFF_STALE','LOAN','CONFLICT','ERROR',409,false,false,'The loan balance changed after the write-off was proposed.','Propose the write-off again.'),
 ('CFMS-LOAN-2016','LOAN_NOT_WRITTEN_OFF','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Only a written-off loan takes a bad debt recovery.','Use a normal repayment.'),
 ('CFMS-APPR-2002','OFFLINE_NOT_ALLOWED','APPR','BUSINESS_RULE','ERROR',422,false,false,'Offline decisions are not allowed for this approval.','Ask the approver to decide online.'),
 ('CFMS-APPR-1003','OFFLINE_APPROVER_REQUIRED','APPR','VALIDATION','ERROR',422,false,false,'Choose who gave the offline decision.','Select the approver.'),
 ('CFMS-APPR-1004','EVIDENCE_TYPE_INVALID','APPR','VALIDATION','ERROR',422,false,false,'Choose a valid evidence type for the offline decision.','Select an active evidence type.'),
 ('CFMS-APPR-1005','EVIDENCE_REQUIRED','APPR','VALIDATION','ERROR',422,false,false,'Upload the evidence for this offline decision.','Attach the evidence document.'),
 ('CFMS-APPR-1006','OFFLINE_DATE_INVALID','APPR','VALIDATION','ERROR',422,false,false,'The decision date must be between the request date and today.','Enter the date the decision was given.'),
 ('CFMS-LOAN-2017','APPLICATION_NOT_EDITABLE','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Only a draft or returned application can be changed.','Withdraw the application and apply again.'),
 ('CFMS-LOAN-2018','APPLICATION_NOT_WITHDRAWABLE','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Only an application that is not yet approved can be withdrawn.','Request a cancellation of the approved loan instead.'),
 ('CFMS-LOAN-2019','LOAN_NOT_CANCELLABLE','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Only an approved loan that is not disbursed can be cancelled.','Check the loan status.'),
 ('CFMS-LOAN-5011','CANCELLATION_ALREADY_PENDING','LOAN','CONFLICT','ERROR',409,false,false,'A cancellation for this loan is already waiting for a decision.','Wait for the decision on the first request.'),
 ('CFMS-LOAN-4010','CANCELLATION_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The cancellation request was not found.','Refresh the requests.'),
 ('CFMS-REPAY-4001','REPAYMENT_NOT_FOUND','REPAY','NOT_FOUND','ERROR',404,false,false,'The repayment was not found.','Refresh the repayments.'),
 ('CFMS-REPAY-2003','REVERSAL_NOT_ALLOWED','REPAY','BUSINESS_RULE','ERROR',422,false,false,'This receipt cannot be reversed.','Settlements, recoveries and receipts of closed-out loans are not reversed here.'),
 ('CFMS-REPAY-2004','REVERSAL_NOT_LATEST','REPAY','BUSINESS_RULE','ERROR',422,false,false,'Only the latest receipt of a loan can be reversed.','Reverse the later receipts first.'),
 ('CFMS-REPAY-5001','REVERSAL_ALREADY_PENDING','REPAY','CONFLICT','ERROR',409,false,false,'A reversal of this receipt is already waiting for approval.','Wait for the decision on the first request.'),
 ('CFMS-REPAY-4002','REVERSAL_NOT_FOUND','REPAY','NOT_FOUND','ERROR',404,false,false,'The reversal request was not found.','Refresh the requests.'),
 ('CFMS-LOAN-2020','GUARANTOR_IS_BORROWER','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The borrower cannot be their own guarantor.','Choose another member.'),
 ('CFMS-LOAN-2021','GUARANTOR_NOT_ELIGIBLE','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The guarantor must be an active member in good standing.','Choose another guarantor.'),
 ('CFMS-LOAN-5012','GUARANTOR_ALREADY_ADDED','LOAN','CONFLICT','ERROR',409,false,false,'This member is already a guarantor for the loan.','Choose another member.'),
 ('CFMS-LOAN-2022','GUARANTOR_LIMIT_REACHED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The member has reached the guarantee limit.','Choose another guarantor.'),
 ('CFMS-LOAN-1010','GUARANTOR_DETAILS_REQUIRED','LOAN','VALIDATION','ERROR',422,false,false,'Choose a member, or enter the name and mobile of the guarantor.','Complete the guarantor details.'),
 ('CFMS-LOAN-1011','GUARANTOR_CONSENT_REQUIRED','LOAN','VALIDATION','ERROR',422,false,false,'Record the guarantor''s signature or thumb impression.','Capture the consent and try again.'),
 ('CFMS-LOAN-1012','INVALID_GUARANTEED_AMOUNT','LOAN','VALIDATION','ERROR',422,false,false,'The guaranteed amount must be positive.','Enter the amount guaranteed.'),
 ('CFMS-LOAN-4011','GUARANTOR_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The guarantor was not found.','Refresh the guarantors.'),
 ('CFMS-LOAN-2023','GUARANTOR_NOT_REPLACEABLE','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Only an open guarantee on a submitted or running loan can be replaced.','Check the guarantee and loan status.'),
 ('CFMS-LOAN-5013','REPLACEMENT_ALREADY_PENDING','LOAN','CONFLICT','ERROR',409,false,false,'A replacement for this guarantor is already waiting for a decision.','Wait for the decision on the first request.'),
 ('CFMS-LOAN-4012','REPLACEMENT_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The replacement request was not found.','Refresh the requests.'),
 ('CFMS-LOAN-2024','GUARANTORS_REQUIRED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The loan needs more guarantors before it can be submitted.','Add the required guarantors.'),
 ('CFMS-LOAN-2025','CASH_LIMIT_APPROVAL_REQUIRED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'This cash disbursement is above the cash limit and needs approval before release.','Ask the approver to approve the cash payment, or pay by bank.'),
 ('CFMS-LOAN-2026','CASH_LIMIT_APPROVAL_NOT_NEEDED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'This disbursement does not need a cash limit approval.','Release the disbursement directly.'),
 ('CFMS-LOAN-2027','TRANCHE_AFTER_LAST_INSTALMENT','LOAN','BUSINESS_RULE','ERROR',422,false,false,'No instalments are left to spread another tranche over.','Restructure the loan or open a new loan.'),
 ('CFMS-LOAN-2028','RESTRUCTURE_NOT_ALLOWED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'This loan cannot be restructured.','Check the loan status and the restructuring setting.'),
 ('CFMS-LOAN-2029','RESTRUCTURE_LIMIT_REACHED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'This loan has already been restructured the maximum number of times.','Contact a manager for other options.'),
 ('CFMS-LOAN-1013','INVALID_RESTRUCTURE_TERMS','LOAN','VALIDATION','ERROR',422,false,false,'The restructuring terms are not valid.','Check the option, tenure, moratorium and rate.'),
 ('CFMS-LOAN-5014','RESTRUCTURE_ALREADY_PENDING','LOAN','CONFLICT','ERROR',409,false,false,'A restructuring request for this loan is already waiting for a decision.','Wait for the decision on the first request.'),
 ('CFMS-LOAN-4013','RESTRUCTURE_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The restructuring request was not found.','Refresh the requests.'),
 ('CFMS-LOAN-2030','DEATH_NOT_VERIFIED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The borrower''s death has not been verified.','Verify the death record first.'),
 ('CFMS-LOAN-1014','INVALID_DECEASED_DECISION','LOAN','VALIDATION','ERROR',422,false,false,'The decision for the deceased member''s loan is not valid.','Choose a listed decision.'),
 ('CFMS-LOAN-5015','DECEASED_DECISION_EXISTS','LOAN','CONFLICT','ERROR',409,false,false,'A decision for this loan has already been recorded.','Open the recorded decision.'),
 ('CFMS-LOAN-2031','TRANSFER_NOT_DECIDED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'The loan can be transferred only after a transfer decision is recorded.','Record the decision to transfer first.'),
 ('CFMS-LOAN-5016','TRANSFER_ALREADY_PROPOSED','LOAN','CONFLICT','ERROR',409,false,false,'A transfer for this loan is already proposed.','Wait for the decision on the proposal.'),
 ('CFMS-LOAN-1015','INVALID_TRANSFER_SHARES','LOAN','VALIDATION','ERROR',422,false,false,'The transfer shares must be positive and add up to 100.','Correct the shares.'),
 ('CFMS-LOAN-2032','SUCCESSOR_NOT_MEMBER','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Each successor must be an active member.','Enrol the successor as a member first.'),
 ('CFMS-LOAN-4014','TRANSFER_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'No transfer proposal was found for this loan.','Propose the transfer first.'),
 ('CFMS-LOAN-4015','MIGRATION_REVIEW_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The migrated loan review was not found.','Refresh the review list.'),
 ('CFMS-LOAN-1016','DOCUMENT_TYPE_INVALID','LOAN','VALIDATION','ERROR',422,false,false,'The document type is not valid.','Choose a listed document type.'),
 ('CFMS-LOAN-1017','DOCUMENT_DETAILS_REQUIRED','LOAN','VALIDATION','ERROR',422,false,false,'The file name and storage location are required.','Upload the file again.'),
 ('CFMS-LOAN-4016','DOCUMENT_NOT_FOUND','LOAN','NOT_FOUND','ERROR',404,false,false,'The document was not found.','Refresh the document list.'),
 ('CFMS-LOAN-2033','DOCUMENTS_REQUIRED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Some required documents are missing.','Attach the listed documents before submitting.'),
 ('CFMS-RPT-1002','INVALID_DATE_RANGE','RPT','VALIDATION','ERROR',422,false,false,'The end date is before the start date.','Choose an end date on or after the start date.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('REPAYMENT_CLEARS_LOAN','இந்தத் தொகை முழுக் கடனையும் தீர்க்கிறது; முன்கூட்டியே தீர்வு மதிப்பீட்டைப் பயன்படுத்தவும்.'),
 ('SCHEDULE_NEEDS_INSTALMENTS','புதிய அட்டவணைக்கு குறைந்தது ஒரு தவணை தேவை.'),
 ('USER_NOT_FOUND','பயனர் கிடைக்கவில்லை அல்லது செயலில் இல்லை.'),
 ('RECOVERY_CASE_NOT_FOUND','திறந்த வசூல் வழக்கு கிடைக்கவில்லை.'),
 ('RECOVERY_OUTCOME_REQUIRED','தொடர்பின் முடிவைப் பதிவு செய்யவும்.'),
 ('PROMISE_DATE_PAST','வாக்குறுதியளித்த செலுத்தும் தேதி கடந்த தேதியாக இருக்கக்கூடாது.'),
 ('INVALID_RECOVERY_STATUS','இந்த வசூல் நிலையை கைமுறையாக அமைக்க முடியாது.'),
 ('INVALID_WAIVER_AMOUNT','தள்ளுபடித் தொகை சரியானதல்ல.'),
 ('WAIVER_NOT_ALLOWED','இந்தத் தள்ளுபடி அனுமதிக்கப்படவில்லை.'),
 ('WAIVER_TARGET_NOT_OPEN','தள்ளுபடி செய்ய எதுவும் நிலுவையில் இல்லை.'),
 ('WAIVER_ALREADY_PENDING','இதற்கான தள்ளுபடி கோரிக்கை ஏற்கனவே அங்கீகாரத்திற்காகக் காத்திருக்கிறது.'),
 ('WAIVER_NOT_FOUND','தள்ளுபடி கோரிக்கை கிடைக்கவில்லை.'),
 ('OVERRIDE_NOT_NEEDED','உறுப்பினர் குளிர்விப்பு காலத்திலோ கட்டுப்பாட்டிலோ இல்லை.'),
 ('OVERRIDE_ALREADY_PENDING','இந்த உறுப்பினருக்கான விலக்கு கோரிக்கை ஏற்கனவே முடிவுக்காகக் காத்திருக்கிறது.'),
 ('OVERRIDE_NOT_FOUND','விலக்கு கோரிக்கை கிடைக்கவில்லை.'),
 ('OPEN_DEFAULT_EXISTS','உறுப்பினருக்கு இன்னும் தீர்க்கப்படாத தவறிய கடன் உள்ளது.'),
 ('WRITE_OFF_NOT_ALLOWED','இந்தக் கடனைத் தள்ளுபடி (write-off) செய்ய முடியாது.'),
 ('WRITE_OFF_ALREADY_PROPOSED','இந்தக் கடனுக்கான write-off ஏற்கனவே முடிவுக்காகக் காத்திருக்கிறது.'),
 ('WRITE_OFF_NOT_FOUND','write-off முன்மொழிவு கிடைக்கவில்லை.'),
 ('WRITE_OFF_STALE','write-off முன்மொழியப்பட்ட பிறகு கடன் இருப்பு மாறியுள்ளது.'),
 ('LOAN_NOT_WRITTEN_OFF','write-off செய்யப்பட்ட கடனுக்கு மட்டுமே வாராக்கடன் வசூல் பதிவு செய்ய முடியும்.'),
 ('OFFLINE_NOT_ALLOWED','இந்த அங்கீகாரத்திற்கு ஆஃப்லைன் முடிவுகள் அனுமதிக்கப்படவில்லை.'),
 ('OFFLINE_APPROVER_REQUIRED','ஆஃப்லைன் முடிவை வழங்கியவரைத் தேர்ந்தெடுக்கவும்.'),
 ('EVIDENCE_TYPE_INVALID','ஆஃப்லைன் முடிவுக்குச் சரியான சான்று வகையைத் தேர்ந்தெடுக்கவும்.'),
 ('EVIDENCE_REQUIRED','இந்த ஆஃப்லைன் முடிவுக்கான சான்றைப் பதிவேற்றவும்.'),
 ('OFFLINE_DATE_INVALID','முடிவுத் தேதி கோரிக்கைத் தேதிக்கும் இன்றைக்கும் இடையில் இருக்க வேண்டும்.'),
 ('APPLICATION_NOT_EDITABLE','வரைவு அல்லது திருப்பி அனுப்பப்பட்ட விண்ணப்பத்தை மட்டுமே மாற்ற முடியும்.'),
 ('APPLICATION_NOT_WITHDRAWABLE','அங்கீகரிக்கப்படாத விண்ணப்பத்தை மட்டுமே திரும்பப் பெற முடியும்.'),
 ('LOAN_NOT_CANCELLABLE','வழங்கப்படாத அங்கீகரிக்கப்பட்ட கடனை மட்டுமே ரத்து செய்ய முடியும்.'),
 ('CANCELLATION_ALREADY_PENDING','இந்தக் கடனுக்கான ரத்து கோரிக்கை ஏற்கனவே முடிவுக்காகக் காத்திருக்கிறது.'),
 ('CANCELLATION_NOT_FOUND','ரத்து கோரிக்கை கிடைக்கவில்லை.'),
 ('REPAYMENT_NOT_FOUND','திருப்பிச் செலுத்துதல் கிடைக்கவில்லை.'),
 ('REVERSAL_NOT_ALLOWED','இந்த ரசீதைத் திரும்பப் பெற முடியாது.'),
 ('REVERSAL_NOT_LATEST','கடனின் கடைசி ரசீதை மட்டுமே திரும்பப் பெற முடியும்.'),
 ('REVERSAL_ALREADY_PENDING','இந்த ரசீதின் திரும்பப்பெறல் ஏற்கனவே அங்கீகாரத்திற்காகக் காத்திருக்கிறது.'),
 ('REVERSAL_NOT_FOUND','திரும்பப்பெறல் கோரிக்கை கிடைக்கவில்லை.'),
 ('GUARANTOR_IS_BORROWER','கடன் பெறுபவர் தனக்குத் தானே பிணையாளராக இருக்க முடியாது.'),
 ('GUARANTOR_NOT_ELIGIBLE','பிணையாளர் நல்ல நிலையில் உள்ள செயலில் உள்ள உறுப்பினராக இருக்க வேண்டும்.'),
 ('GUARANTOR_ALREADY_ADDED','இந்த உறுப்பினர் ஏற்கனவே இந்தக் கடனுக்குப் பிணையாளர்.'),
 ('GUARANTOR_LIMIT_REACHED','உறுப்பினர் பிணை வரம்பை அடைந்துவிட்டார்.'),
 ('GUARANTOR_DETAILS_REQUIRED','உறுப்பினரைத் தேர்ந்தெடுக்கவும், அல்லது பிணையாளரின் பெயரும் கைபேசி எண்ணும் உள்ளிடவும்.'),
 ('GUARANTOR_CONSENT_REQUIRED','பிணையாளரின் கையொப்பம் அல்லது கைரேகையைப் பதிவு செய்யவும்.'),
 ('INVALID_GUARANTEED_AMOUNT','பிணைத் தொகை நேர்மறையாக இருக்க வேண்டும்.'),
 ('GUARANTOR_NOT_FOUND','பிணையாளர் கிடைக்கவில்லை.'),
 ('GUARANTOR_NOT_REPLACEABLE','சமர்ப்பிக்கப்பட்ட அல்லது நடப்பிலுள்ள கடனின் திறந்த பிணையை மட்டுமே மாற்ற முடியும்.'),
 ('REPLACEMENT_ALREADY_PENDING','இந்தப் பிணையாளரை மாற்றும் கோரிக்கை ஏற்கனவே முடிவுக்காகக் காத்திருக்கிறது.'),
 ('REPLACEMENT_NOT_FOUND','மாற்றுக் கோரிக்கை கிடைக்கவில்லை.'),
 ('GUARANTORS_REQUIRED','சமர்ப்பிக்கும் முன் கடனுக்கு மேலும் பிணையாளர்கள் தேவை.'),
 ('CASH_LIMIT_APPROVAL_REQUIRED','இந்த ரொக்கப் பட்டுவாடா ரொக்க வரம்பை மீறுகிறது; வெளியிடும் முன் ஒப்புதல் தேவை.'),
 ('CASH_LIMIT_APPROVAL_NOT_NEEDED','இந்தப் பட்டுவாடாவுக்கு ரொக்க வரம்பு ஒப்புதல் தேவையில்லை.'),
 ('TRANCHE_AFTER_LAST_INSTALMENT','மற்றொரு தவணைப் பகுதியைப் பகிர்ந்தளிக்க மீதமுள்ள தவணைகள் இல்லை.'),
 ('RESTRUCTURE_NOT_ALLOWED','இந்தக் கடனை மறுசீரமைக்க முடியாது.'),
 ('RESTRUCTURE_LIMIT_REACHED','இந்தக் கடன் அதிகபட்ச எண்ணிக்கையில் ஏற்கனவே மறுசீரமைக்கப்பட்டுள்ளது.'),
 ('INVALID_RESTRUCTURE_TERMS','மறுசீரமைப்பு நிபந்தனைகள் சரியானவை அல்ல.'),
 ('RESTRUCTURE_ALREADY_PENDING','இந்தக் கடனுக்கான மறுசீரமைப்புக் கோரிக்கை ஏற்கனவே முடிவுக்காகக் காத்திருக்கிறது.'),
 ('RESTRUCTURE_NOT_FOUND','மறுசீரமைப்புக் கோரிக்கை கிடைக்கவில்லை.'),
 ('DEATH_NOT_VERIFIED','கடனாளியின் மரணம் சரிபார்க்கப்படவில்லை.'),
 ('INVALID_DECEASED_DECISION','இறந்த உறுப்பினரின் கடனுக்கான முடிவு சரியானதல்ல.'),
 ('DECEASED_DECISION_EXISTS','இந்தக் கடனுக்கான முடிவு ஏற்கனவே பதிவு செய்யப்பட்டுள்ளது.'),
 ('TRANSFER_NOT_DECIDED','மாற்ற முடிவு பதிவு செய்த பின்னரே கடனை மாற்ற முடியும்.'),
 ('TRANSFER_ALREADY_PROPOSED','இந்தக் கடனுக்கான மாற்றம் ஏற்கனவே முன்மொழியப்பட்டுள்ளது.'),
 ('INVALID_TRANSFER_SHARES','மாற்றப் பங்குகள் நேர்மறையாகவும் மொத்தம் 100 ஆகவும் இருக்க வேண்டும்.'),
 ('SUCCESSOR_NOT_MEMBER','ஒவ்வொரு வாரிசும் செயலில் உள்ள உறுப்பினராக இருக்க வேண்டும்.'),
 ('TRANSFER_NOT_FOUND','இந்தக் கடனுக்கான மாற்ற முன்மொழிவு கிடைக்கவில்லை.'),
 ('MIGRATION_REVIEW_NOT_FOUND','இடம்பெயர்ந்த கடன் மறுஆய்வு கிடைக்கவில்லை.'),
 ('DOCUMENT_TYPE_INVALID','ஆவண வகை சரியானதல்ல.'),
 ('DOCUMENT_DETAILS_REQUIRED','கோப்புப் பெயரும் சேமிப்பு இடமும் தேவை.'),
 ('DOCUMENT_NOT_FOUND','ஆவணம் கிடைக்கவில்லை.'),
 ('DOCUMENTS_REQUIRED','சில தேவையான ஆவணங்கள் இல்லை.'),
 ('INVALID_DATE_RANGE','முடிவுத் தேதி தொடக்கத் தேதிக்கு முன் உள்ளது.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;

-- -----------------------------------------------------------------------------
-- Settings used by the loan additions. Other keys they read already exist:
-- loans.cooling_off, loans.payment_allocation_order, notifications.quiet_hours,
-- notifications.loan_reminder_schedule, recovery.escalate_to_*_days.
-- -----------------------------------------------------------------------------
SET app.channel TO 'MIGRATION';
WITH s(setting_key, area, name, data_type, editable_by, value, scope_ref, is_proposed, sort_order) AS (VALUES
 ('loans.write_off_approver_role','Loans','Write-off approver role','string','SUPER_ADMIN','"LDR"'::jsonb,'6.11',false,70),
 ('migration.go_live_date','Migration','Go-live date (migrated loans overdue before it are reviewed, not defaulted)','date','SUPER_ADMIN','null','39.3',false,170),
 ('loans.age_limits','Loans','Borrower age limits (years; a loan type AGE_LIMITS rule wins)','json','SUPER_ADMIN','{"minAtApplication":18,"maxAtApplication":null,"maxAtMaturity":null,"requireDateOfBirth":false}','6.2',false,71),
 ('loans.exposure_limits','Loans','Maximum outstanding principal per member and per household (null = no limit)','json','SUPER_ADMIN','{"perMember":null,"perHousehold":null}','6.2',false,72),
 ('loans.guarantor_limits','Loans','Guarantor limits (open guarantees per member, total guaranteed amount)','json','SUPER_ADMIN','{"maxActiveGuarantees":2,"maxGuaranteedTotal":null}','6.9',false,73),
 ('cash.disbursement_limit','Cash','Cash disbursement limit (above it, approval is needed before release; null = no limit)','json','SUPER_ADMIN','{"amount":null,"approverRole":"LDR"}','21.6',false,132)
),
d AS (
    INSERT INTO platform.setting_definition (setting_key, area, name, data_type, editable_by, scope_ref, is_proposed, sort_order)
    SELECT setting_key, area, name, data_type, editable_by, scope_ref, is_proposed, sort_order FROM s
    ON CONFLICT (setting_key) DO UPDATE SET area = EXCLUDED.area, name = EXCLUDED.name, data_type = EXCLUDED.data_type,
        editable_by = EXCLUDED.editable_by, scope_ref = EXCLUDED.scope_ref, is_proposed = EXCLUDED.is_proposed,
        sort_order = EXCLUDED.sort_order
    RETURNING setting_key
)
INSERT INTO platform.settings_template_item (version_no, setting_key, value)
SELECT 1, s.setting_key, s.value FROM s
ON CONFLICT DO NOTHING;

SET app.scope TO 'platform';
INSERT INTO cfg.tenant_setting (tenant_id, setting_key, value, effective_from, status, source, template_version, reason)
SELECT t.id, i.setting_key, i.value, DATE '2000-01-01', 'ACTIVE', 'TEMPLATE', 1,
       'Default added from settings template v1 (loan additions)'
  FROM platform.tenant t
  JOIN platform.settings_template_item i ON i.version_no = 1
 WHERE i.setting_key IN ('loans.write_off_approver_role','migration.go_live_date','loans.age_limits',
                         'loans.exposure_limits','loans.guarantor_limits','cash.disbursement_limit')
   AND NOT EXISTS (SELECT 1 FROM cfg.tenant_setting x WHERE x.tenant_id = t.id AND x.setting_key = i.setting_key);
RESET app.scope;

-- -----------------------------------------------------------------------------
-- Notification templates (platform defaults, English) for the new events.
-- -----------------------------------------------------------------------------
INSERT INTO platform.notification_template_default (code, channel, language_code, name, subject, body, module_code, is_essential) VALUES
 ('GUARANTOR_DEFAULT_NOTICE','SMS','en','Guarantor default notice',NULL,'Dear {{member_name}}, loan {{loan_no}} of {{borrower_name}}, for which you are a guarantor, is in default. Please contact the office. - {{org_name}}','LOAN_DEFAULT',true),
 ('NOMINEE_DEFAULT_NOTICE','SMS','en','Nominee default notice',NULL,'Dear {{member_name}}, loan {{loan_no}} of {{borrower_name}}, for which you are a nominee, is in default. - {{org_name}}','LOAN_DEFAULT',true)
ON CONFLICT DO NOTHING;
