from __future__ import annotations

import smtplib
from email.message import EmailMessage

from app.core.config import settings


def send_password_reset_email(email: str, token: str) -> None:
    if not settings.smtp_host:
        raise RuntimeError("SMTP_HOST is not configured.")
    message = EmailMessage()
    message["Subject"] = "Reset your PDFree Editor password"
    message["From"] = settings.smtp_from
    message["To"] = email
    message.set_content(
        f"Reset your password with this token:\n\n{token}\n\n"
        f"This token expires in {settings.password_reset_expire_minutes} minutes."
    )
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as smtp:
        if settings.smtp_starttls:
            smtp.starttls()
        if settings.smtp_username:
            smtp.login(settings.smtp_username, settings.smtp_password or "")
        smtp.send_message(message)


def send_premium_request_email(email: str) -> None:
    if not settings.smtp_host or not settings.admin_email:
        raise RuntimeError("SMTP_HOST and ADMIN_EMAIL are not configured.")
    message = EmailMessage()
    message["Subject"] = "PDFree Editor premium request"
    message["From"] = settings.smtp_from
    message["To"] = settings.admin_email
    message.set_content(f"User requested premium activation: {email}")
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as smtp:
        if settings.smtp_starttls:
            smtp.starttls()
        if settings.smtp_username:
            smtp.login(settings.smtp_username, settings.smtp_password or "")
        smtp.send_message(message)
