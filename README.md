# AI Teaching Assistant V2 — Streamlit + Supabase + OpenAI

## 1. Supabase
1. Create a project at https://supabase.com.
2. Open SQL Editor, paste and run `schema.sql`.
3. In Authentication > Providers, enable Email; configure confirmation emails as appropriate.
4. Copy the project URL and **publishable/anon** key from project settings. Never use a service-role/secret key in this app.

## 2. Streamlit secrets
Copy `.streamlit/secrets.toml.example` to `.streamlit/secrets.toml` and enter your credentials. Do not commit secrets.toml to GitHub. For Streamlit Cloud, add the same values in app Settings > Secrets.

## 3. Run locally
```
python -m pip install -r requirements.txt
python -m streamlit run app.py
```

## 4. Create teacher account
Sign up using the application (all registrations are student-only). Confirm your email and then run this **in Supabase SQL Editor**, replacing the email with your own:
```
update public.profiles set role='teacher' where email='your-teacher-email@example.com';
```
Sign out and sign back in. Students remain student accounts.

## 5. Deploy
Create a private GitHub repo and push these files, excluding `.streamlit/secrets.toml`. In https://share.streamlit.io create an app from the repo and set the main file to `app.py`. Add secrets through the Streamlit Cloud dashboard. Never commit API keys.

## Notes and limitations
- V2 is a prototype, not an institutional-grade LMS. Review privacy policy, university requirements, account recovery, retention and hosting before real student data.
- Each assessment currently has one text question; each student can submit once. There is no deadline, resubmission or multi-question MCQ engine yet.
- Teacher manually reviews and approves all grades; AI grading is optional and provisional.
- Student results are retrieved only through a restricted RPC that returns scores/feedback after approval. Teachers can read submissions for assessments they own.
- PDF extraction works on text PDFs, not scanned images; no OCR is included.
- Students see all published assessments; course enrollment and class-specific visibility are future features.
- OpenAI requests can transmit assignment content to the model provider; use test data until data governance is approved.
- No automatic plagiarism detection, numeric verification or AI grading audit log yet.
- For production, use a managed identity solution, monitoring, backups, secure retention, class-level authorization, and formal security review.
