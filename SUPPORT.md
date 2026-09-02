# Sāmwaad (संवाद) — Support & Help Centre

Welcome to the **Sāmwaad Support Centre**. Sāmwaad is an accessibility-first iOS application engineered for real-time speech captioning, on-device AI speaker diarization, and smart meeting summaries.

---

## 🛠️ Frequently Asked Questions (FAQ)

### 1. Why does Sāmwaad need Microphone and Speech Recognition permissions?
Sāmwaad uses Apple's **Speech** framework to convert spoken conversation into text on screen in real time and utilizes audio buffers to identify distinct speakers using our on-device CoreML model (`VL1004`). Audio is never stored as raw recordings or uploaded to third-party servers.

### 2. How do I calibrate my voice for speaker identification?
1. Open Sāmwaad and navigate to **Profile > Vocal Profile**.
2. Tap **Voice Calibration**.
3. Follow the 3-sentence calibration prompt in a quiet environment.
4. Once completed, your voice profile will show **"Calibrated"** and Sāmwaad will tag your utterances in blue bubbles.

### 3. How do Group Sessions work?
* **Creating a Room:** Tap **Group Sessions > Create Session**. Share the 6-digit room code with other participants.
* **Joining a Room:** Tap **Group Sessions > Join Session** and enter the host's 6-digit room code.
* All group session data is protected via client-side AES-256 encryption.

### 4. Which devices support Apple Intelligence Summaries?
Post-session AI summaries and action item generation leverage Apple Foundation Models available on **iPhone 15 Pro, iPhone 15 Pro Max, and all iPhone 16 models** running iOS 18+. On other devices running iOS 17+, Sāmwaad uses built-in localized summarization routines.

### 5. How can I delete my data or account?
* To delete your voice profile: **Profile > Vocal Profile > Delete Profile**.
* To delete your full account and cloud data: **Profile > Delete Account**.
* To clear all conversation logs: Open **View Conversations** and select **Clear All History**.

---

## 📞 Contact & Support Channels

If you encounter any issues, bugs, or have feature suggestions:

* **Support Email:** support.samwaad@gmail.com
* **Issue Tracker:** [GitHub Issues](https://github.com/MITWPU-Group04/issues)
* **Website / Documentation:** [Sāmwaad GitHub Repository](https://github.com/MITWPU-Group04)
* **Organization:** MIT-WPU Faculty of Engineering & Technology (Group 4)
