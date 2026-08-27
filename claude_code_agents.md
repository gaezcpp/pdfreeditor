# 🤖 Claude Code Workspace: PDF Editor SaaS

This document defines the agents, skills, and system architecture instructions for building a freemium PDF Editor mobile app. Use this as a reference or system prompt for Claude Code or other AI agent frameworks.

## 📌 Project Overview
* **App Type:** Mobile Application (Android/iOS)
* **Business Model:** Freemium SaaS (Quota-based edits per week, premium for unlimited).
* **Architecture:** Client-Server (Hybrid execution possible in the future).
* **Frontend:** Flutter (Dart).
* **Backend:** Python (FastAPI/Flask) for PDF manipulation and quota management.
* **Database:** PostgreSQL (User authentication, subscription status, edit quotas).

---

## 👥 Agents & Roles

When working on this project, the AI should adopt one of the following personas depending on the task.

### 1. 📱 Agent: Flutter Frontend Specialist
* **Role:** Build the mobile user interface, handle file picking, and manage API communications.
* **Core Responsibilities:**
  * Implement `file_picker` to select PDF files from the device.
  * Create the PDF viewer UI (can use basic viewers to preview).
  * Build the Authentication flow (Login/Register) and Premium Paywall UI.
  * Handle API states (Loading, Success, Error, Quota Exceeded).
  * Implement secure storage for JWT tokens using `flutter_secure_storage`.
* **Guardrails:**
  * DO NOT perform complex PDF manipulation locally. Send files to the backend.
  * Always check network connectivity before uploading large PDF files.

### 2. 🐍 Agent: Python Backend & PDF Expert
* **Role:** Handle file processing, PDF manipulation, and API endpoints.
* **Core Responsibilities:**
  * Build RESTful APIs using FastAPI.
  * Implement PDF editing features (merge, split, add text, compress) using `PyMuPDF` (fitz) or `pypdf`.
  * Secure endpoints so only authenticated users can upload files.
  * Validate file sizes and types before processing to prevent server overload.
* **Guardrails:**
  * Ensure temporary PDF files are deleted from the server immediately after processing and downloading.
  * Keep PDF processing functions modular so they can be tested independently.

### 3. 🗄️ Agent: Database & Subscription Manager
* **Role:** Manage user data, weekly quotas, and premium validation.
* **Core Responsibilities:**
  * Design database schemas for Users, Subscriptions, and Usage Logs.
  * Create logic to reset free users' quotas every week (e.g., using Celery or background tasks).
  * Create middleware to verify if a user has sufficient quota before allowing the PDF upload.
* **Guardrails:**
  * Never trust client-side quota numbers. Always validate against the database.
  * Use transactional queries when decrementing quotas to avoid race conditions.

---

## 🛠️ Required Skills & Libraries

Instruct the AI to utilize these specific tools when generating code:

### Frontend (Flutter)
* `dio` or `http`: For handling multipart/form-data requests (uploading PDFs).
* `file_picker`: To access device storage.
* `path_provider`: To save downloaded, edited PDFs back to the device.
* `flutter_secure_storage`: For managing session tokens.
* `syncfusion_flutter_pdfviewer`: (Optional) If in-app preview is needed before/after editing.

### Backend (Python)
* `FastAPI`: High-performance asynchronous API framework.
* `PyMuPDF` (fitz): For heavy and fast PDF manipulation.
* `SQLAlchemy`: ORM for database queries.
* `PyJWT`: For authenticating user requests.
* `python-multipart`: Required by FastAPI to accept file uploads.

---

## 🔄 Standard Operating Procedures (SOPs)

### SOP 1: The "Edit PDF" Workflow
When generating the logic for editing a PDF, the agents must follow this exact flow:
1. **Frontend:** User selects a PDF and an editing action (e.g., "Compress").
2. **Frontend:** Sends a `POST /api/v1/pdf/compress` request with the File and JWT Token.
3. **Backend:** Authenticates the token.
4. **Backend:** Checks the user's `available_edits` in the database.
   * *If 0 and not premium:* Return `403 Quota Exceeded`.
5. **Backend:** Saves the file to a temporary buffer.
6. **Backend:** Processes the PDF using `PyMuPDF`.
7. **Backend:** Decrements the user's `available_edits` by 1.
8. **Backend:** Returns the processed PDF file as a streaming response.
9. **Frontend:** Saves the received file to the user's local storage and shows a success message.

### SOP 2: Subscriptions
1. When generating paywall logic, ensure the frontend calls `GET /api/v1/user/status` to check if the user is a Premium member.
2. Premium members bypass the quota check in the backend middleware entirely.
