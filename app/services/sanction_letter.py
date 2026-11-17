"""Render the loan sanction letter as a printable HTML page.

The data comes from loan.sanction_letter(); every value is escaped, so member
names or addresses cannot inject markup.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation
from html import escape
from typing import Any


def _text(value: Any) -> str:
    return "" if value is None else escape(str(value))


def _money(value: Any, currency: str | None = None) -> str:
    if value is None:
        return ""
    try:
        amount = f"{Decimal(str(value)):,.2f}"
    except (InvalidOperation, ValueError):
        amount = str(value)
    return escape(f"{currency} {amount}" if currency else amount)


def _date(value: Any) -> str:
    return _text(str(value)[:10]) if value else ""


def render_sanction_letter(data: dict[str, Any]) -> str:
    org = data.get("organisation") or {}
    member = data.get("member") or {}
    loan = data.get("loan") or {}
    fee = data.get("fee") or {}
    currency = org.get("currency_code")
    rows = [
        ("Loan number", _text(loan.get("loan_no"))),
        ("Loan type", _text(loan.get("loan_type_name"))),
        ("Purpose", _text(loan.get("purpose"))),
        ("Sanctioned amount", _money(loan.get("approved_amount"), currency)),
        ("Tenure", f"{_text(loan.get('tenure_months'))} months"),
        ("Interest rate", f"{_text(loan.get('interest_rate_annual'))} % a year ({_text(loan.get('interest_method'))})"),
        ("Total interest", _money(loan.get("total_interest"), currency)),
        ("Monthly instalment", _money(loan.get("instalment_amount"), currency)),
        ("First instalment due", _date(loan.get("first_due_date"))),
        ("Last instalment due", _date(loan.get("maturity_date"))),
        ("Offer valid until", _date(loan.get("approval_expires_on"))),
    ]
    if fee:
        rows.append(("Processing fee", f"{_money(fee.get('fee_amount'), currency)} ({_text(fee.get('collect_timing'))})"))
    terms = "".join(f"<tr><th>{label}</th><td>{value}</td></tr>" for label, value in rows)
    guarantors = "".join(
        f"<li>{_text(g.get('name'))}{' (' + _text(g.get('member_no')) + ')' if g.get('member_no') else ''}"
        f" for {_money(g.get('guaranteed_amount'), currency)}</li>" for g in data.get("guarantors") or [])
    nominees = "".join(f"<li>{_text(n.get('name'))} ({_text(n.get('relationship'))})</li>"
                       for n in data.get("nominees") or [])
    schedule_rows = "".join(
        f"<tr><td>{_text(i.get('instalment_no'))}</td><td>{_date(i.get('due_date'))}</td>"
        f"<td class='n'>{_money(i.get('principal'))}</td><td class='n'>{_money(i.get('interest'))}</td>"
        f"<td class='n'>{_money(i.get('total'))}</td></tr>" for i in data.get("schedule") or [])
    schedule = (
        "<table class='schedule'><thead><tr><th>No.</th><th>Due date</th><th>Principal</th><th>Interest</th>"
        f"<th>Total</th></tr></thead><tbody>{schedule_rows}</tbody></table>"
        if schedule_rows else "<p>The repayment schedule is issued when the loan is disbursed.</p>")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sanction letter {_text(loan.get('loan_no'))}</title>
<style>
body{{font-family:Georgia,serif;max-width:760px;margin:24px auto;padding:0 16px;color:#111;background:#fff}}
header{{border-bottom:2px solid #111;margin-bottom:16px}} h1{{margin:0;font-size:22px}} h2{{font-size:16px;margin-top:24px}}
table{{border-collapse:collapse;width:100%}} th,td{{text-align:left;padding:4px 8px;border-bottom:1px solid #ddd;vertical-align:top}}
.schedule td.n{{text-align:right}} .sign{{display:flex;justify-content:space-between;margin-top:56px}}
@media print{{body{{margin:0}}}}
</style></head><body>
<header><h1>{_text(org.get('legal_name') or org.get('name'))}</h1>
<p>{_text(org.get('address'))}{' &middot; Reg. no. ' + _text(org.get('registration_no')) if org.get('registration_no') else ''}</p></header>
<p>Date: {_date(data.get('generated_on'))}</p>
<p>To<br>{_text(member.get('full_name'))} (Member no. {_text(member.get('member_no'))})<br>{_text(member.get('address'))}</p>
<h2>Loan sanction letter</h2>
<p>We are pleased to inform you that your loan application dated {_date(loan.get('application_date'))}
has been sanctioned on the following terms.</p>
<table class="terms">{terms}</table>
<h2>Guarantors</h2>{'<ul>' + guarantors + '</ul>' if guarantors else '<p>None.</p>'}
<h2>Nominees</h2>{'<ul>' + nominees + '</ul>' if nominees else '<p>None.</p>'}
<h2>Repayment schedule</h2>{schedule}
<h2>Conditions</h2>
<ol><li>Instalments are payable on or before the due date. Late payment attracts the charges in force.</li>
<li>Early settlement follows the policy: {_text(loan.get('early_settlement_policy')) or 'as per the rules in force'}.</li>
<li>The organisation may recover dues from guarantors as per its rules if the loan is not repaid.</li></ol>
<div class="sign"><div>Sanctioned by<br><br>{_text(data.get('approved_by'))}</div>
<div>Accepted by the borrower<br><br>{_text(member.get('full_name'))}</div></div>
</body></html>"""
