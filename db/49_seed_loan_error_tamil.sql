-- =============================================================================
-- CFMS / NVS  -  49  Tamil text for loan and repayment error codes
-- -----------------------------------------------------------------------------
-- Run as nvs after 44-48. Safe to re-run. Placeholders ({date}, {status},
-- {total}, {approved}, {amount}, {allocated}) match the English templates.
-- =============================================================================

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('APPROVAL_EXPIRED','ஒப்புதல் {date} அன்று காலாவதியானது; கடனை மீண்டும் அங்கீகரிக்க வேண்டும்.'),
 ('APPROVED_TERMS_OUT_OF_RANGE','அங்கீகரிக்கப்பட்ட தொகையும் காலமும் விண்ணப்பத்தில் கேட்டதை விட அதிகமாக இருக்கக்கூடாது.'),
 ('DISBURSEMENT_STATE','இந்த வழங்கல் வெளியீட்டுக்காக காத்திருக்கவில்லை.'),
 ('FEE_EXCEEDS_DISBURSEMENT','விண்ணப்பக் கட்டணம் மொத்த வழங்கல் தொகையை விடக் குறைவாக இருக்க வேண்டும்.'),
 ('LOAN_APPROVER_IS_CREATOR','விண்ணப்பத்தை உருவாக்கிய பணியாளர் அதை அங்கீகரிக்க முடியாது.'),
 ('LOAN_NOT_APPROVED','{status} நிலையில் உள்ள கடனை வழங்க முடியாது.'),
 ('LOAN_NOT_OPEN','இந்தக் கடன் திருப்பிச் செலுத்துதலுக்குத் திறந்திருக்கவில்லை.'),
 ('LOAN_TERMS_REQUIRED','கடனை அங்கீகரிக்க அங்கீகரிக்கப்பட்ட தொகை, காலம் மற்றும் விதிமுறைகள் தேவை.'),
 ('OVER_DISBURSEMENT','வழங்கல்கள் ({total}) அங்கீகரிக்கப்பட்ட தொகை {approved}-ஐ விட அதிகமாகும்.'),
 ('TRANCHE_NOT_SUPPORTED','கூடுதல் கடன் வழங்கல் தவணைகள் இயக்கப்படவில்லை.'),
 ('ALLOCATION_MISMATCH','{amount} திருப்பிச் செலுத்துதலில் {allocated} மட்டுமே ஒதுக்கப்பட்டுள்ளது.'),
 ('INVALID_REPAYMENT_AMOUNT','திருப்பிச் செலுத்தும் தொகை பூஜ்ஜியத்தை விட அதிகமாக இருக்க வேண்டும்.'),
 ('REPAYMENT_ONE_SOURCE','திருப்பிச் செலுத்துதல் ஒரே ஒரு மூலத்திலிருந்து வர வேண்டும் (ரசீது, சம்பளப் பிடித்தம், வைப்பு அல்லது பதிவேடு).')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;
