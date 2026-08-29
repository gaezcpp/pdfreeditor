from fastapi import APIRouter

from app.api.v1 import auth, editor, pdf, users

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(users.router)
api_router.include_router(pdf.router)
api_router.include_router(editor.router)
