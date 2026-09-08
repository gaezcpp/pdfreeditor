from __future__ import annotations

from pydantic import BaseModel, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    # 72 bytes is bcrypt's hard limit; anything longer is silently truncated.
    password: str = Field(min_length=8, max_length=72)
    full_name: str | None = Field(default=None, max_length=120)
    device_label: str | None = Field(default=None, max_length=120)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=72)
    device_label: str | None = Field(default=None, max_length=120)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=512)


class PasswordResetRequest(BaseModel):
    email: EmailStr


class PasswordResetConfirm(BaseModel):
    token: str = Field(min_length=32, max_length=512)
    password: str = Field(min_length=8, max_length=72)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"  # noqa: S105  — the OAuth scheme name
    expires_in: int
