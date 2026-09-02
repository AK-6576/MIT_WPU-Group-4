# Privacy Policy for Sāmwaad (संवाद)

**Last Updated:** September 2, 2026

**Sāmwaad** ("we", "our", or "us") is dedicated to protecting your privacy. This Privacy Policy explains how our native iOS application collects, uses, processes, and protects your information when you use the Sāmwaad mobile application.

---

## 1. Summary & Core Privacy Principles

* **On-Device Audio Processing:** Your voice audio captured during live transcription and speaker calibration is processed locally on your device in memory. We **never** stream, record, or upload raw audio files to any external cloud servers.
* **On-Device Machine Learning:** Speaker diarization uses a local CoreML model (`VL1004`) to compute anonymous voice embeddings directly on Apple Neural Engine / GPU hardware.
* **Client-Side Encryption (CSE):** All shared group session metadata and transcripts synced to our cloud database (Firebase Realtime Database) are encrypted end-to-end on your device using AES-GCM-256 before transmission.
* **No Third-Party Ad Trackers:** We do not sell your data, display third-party advertisements, or track your activity across other apps and websites.

---

## 2. Information We Collect and How We Use It

### A. Microphone & Spoken Audio Data
* **Purpose:** To provide real-time speech-to-text live captioning and on-device speaker identification.
* **Processing:** Audio captured through your microphone is buffered temporarily in RAM to run Apple's `SFSpeechRecognizer` and our local CoreML model. Once processed, temporary audio buffers are immediately discarded from memory.
* **Storage:** Raw audio is **never** saved to disk or uploaded to any remote server.

### B. Voice Calibration Profile (Voice Embeddings)
* **Purpose:** To associate your speech with your chosen speaker identity (e.g., "You").
* **Storage:** Voice calibration extracts numerical mathematical vectors (embeddings) representing vocal acoustic properties. These embeddings are stored strictly locally in your device's private sandbox using Apple SwiftData.
* **Control:** You can delete or re-calibrate your voice profile at any time in **Settings > Vocal Profile**.

### C. Account & Authentication Information
* **Information:** If you register an account, we collect your email address and authentication credentials via Firebase Authentication / Google Sign-In.
* **Purpose:** To securely manage your identity, enable cross-device session synchronization, and protect your private group sessions.

### D. Group Sessions & Conversation Transcripts
* **Information:** Text transcripts, participant names, action routines, and session summaries.
* **Storage & Encryption:** Synced transcripts are protected using AES-256 client-side encryption. Keys are stored in the iOS Keychain (`kSecClassGenericPassword`) and are never accessible to database administrators in plaintext.
* **Local Storage:** Transcripts are saved locally on your device via SwiftData for offline review.

### E. Location Data (Optional)
* **Purpose:** If enabled, reverse geocoding provides geographic context (e.g., city or venue name) for auto-generated meeting summary notes.
* **Processing:** Handled via Apple CoreLocation during active sessions only when granted "While Using the App".

---

## 3. Apple Intelligence & On-Device Summaries

Sāmwaad utilizes on-device Foundation Models (Apple Intelligence) on supported hardware (iPhone 15 Pro and later) to generate post-session summaries, action items, and meeting notes. All natural language summarization executes on-device without routing conversation transcripts to external AI model APIs.

---

## 4. Data Retention & Deletion Rights

You have complete control over your personal data:

1. **Delete Voice Profile:** Remove stored voice calibration vectors under **Profile > Vocal Profile > Delete Profile**.
2. **Clear History:** Wipe all saved conversation transcripts and chat logs directly within the app.
3. **Account Deletion:** You can request permanent account deletion by navigating to **Profile > User Details > Delete Account** or by contacting support. Deleting your account immediately and permanently purges your authentication record, cloud storage nodes (`/users/{uid}`), and local SwiftData records.

---

## 5. Third-Party Services

We integrate with trusted Apple system frameworks and Google Firebase infrastructure:
* **Apple Speech Framework & CoreML:** Local on-device inference and Apple-governed speech recognition.
* **Firebase Authentication & Realtime Database:** For secure account login and encrypted group room synchronization. Governed by [Google Cloud Privacy Policy](https://cloud.google.com/terms/cloud-privacy-notice).

---

## 6. Children's Privacy

Sāmwaad does not knowingly collect or solicit personal information from children under the age of 13.

---

## 7. Contact Us

If you have questions, feedback, or data privacy requests, please contact our team:

* **Project Team:** MIT-WPU Group 4 (ANSD Accessibility Initiative)
* **Email:** support.samwaad@gmail.com
* **GitHub Repository:** [https://github.com/MITWPU-Group04](https://github.com/MITWPU-Group04)
