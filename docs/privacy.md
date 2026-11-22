# Privacy & security

*[Deutsche Version](privacy.de.md)*

Family AI Server is built for families who want to keep their data close. The app and all data run on **your** Mac. Only what is needed for an answer goes to OpenRouter and the model. This page describes exactly what that is, what the app does on its own to protect it, and **what you, as the family admin, should configure in OpenRouter**.

## What stays with you

Everything else stays local on the server: accounts and passwords, passkeys, all chats, memory, uploaded documents and images, settings, usage data and the backups. The parental view and the admin area only read this local data.

## What goes to OpenRouter and the model

| Feature | What is sent |
|---|---|
| Chat | the chat messages, attachments and images, the system prompt (AI name, the person's **first name only**, date, your custom instructions, memory entries if memory is on) |
| Document search | text passages of the documents and the search query (for embeddings); on a hit, the matching passages in the chat |
| Web search | the search query written by the model |
| Images, read-aloud, dictation | the image prompt, the text to read aloud, or the voice recording |
| Chat titles | the first message of the chat |

**Not** sent: surname and family name, passwords, e-mail addresses, account and admin data, other people's chats and the backups.

## What the app does on its own

Always on, no setting needed:

- **No retention requested:** every request to OpenRouter asks for Zero Data Retention (`provider.zdr`) and no data collection by the provider (`data_collection: deny`). This covers chat, web search, embeddings, images, read-aloud and dictation, and it is set in one central place in the code so no call can miss it. It only ever tightens and complements the guardrail in OpenRouter (see below).
- **First name only:** the system prompt says "You are talking with <first name>". Surname and family name never reach the model.
- **Pseudonymous identifier:** chat requests carry a hash of the user ID in the `user` field instead of a name.
- **Web search through the model provider:** the engine is fixed to `native`. The search runs at the same provider as the answer, with no extra third party such as Exa or Firecrawl.
- **One key per person:** costs and limits are separate and a key can be revoked individually. Keys are stored in the macOS Keychain.
- **Child protection:** children get a fixed note in the system prompt; image models with content moderation reject unsuitable requests (tested e.g. with `microsoft/mai-image-2.7-flash`).

## OpenRouter settings (family admin)

The app requests "no retention" in every request. In addition, you should **enforce it in the OpenRouter account**. Then it applies to every key, including future or foreign ones, and nobody can bypass it by accident. Labels may change at OpenRouter.

### 1. Account settings (`openrouter.ai/settings/privacy`)

- Disable routing to providers that **may train on your inputs** (for paid and for free models).
- Enable **ZDR** for the provider groups you use (Anthropic, OpenAI, Google, xAI, "other").

### 2. Guardrail in the default workspace (`openrouter.ai/workspaces/default/guardrails`)

One guardrail that applies to all keys of the workspace:

| Setting | Recommendation |
|---|---|
| Mode | "Allow all except" (or your own model list, see below) |
| ZDR for Anthropic, OpenAI, Google, xAI and "Other" | **on** |
| Free training | **off** |
| Data regions | "Any region" – an EU region exists only on the Business/Enterprise plan, without web search there (see "Limits") |
| Budget | optional per person (see 3) |

### 3. One key per person

- Create one key per person and set a **monthly limit**. This caps costs and separates usage. The app shows usage and mails at 80 % and 100 %.
- Optionally a stricter guardrail (model list) per child if you want to restrict the choice. Then the models for images, read-aloud, dictation and embeddings must be allowed there too.

### 4. Pick ZDR-capable models for the extra features

Not every model has an endpoint without retention. If you pick one without, OpenRouter rejects the request and the feature fails. Tested in November 2026 (this changes, please verify yourself):

| Feature | Works with ZDR | Does not work with ZDR |
|---|---|---|
| Chat | Anthropic and OpenAI models (e.g. Claude Haiku/Sonnet, GPT-6 Luna/Sol) | Google Gemini chat |
| Embeddings (documents) | `openai/text-embedding-3-large`/`-small`, `mistralai/mistral-embed-2312`, `qwen/qwen3-embedding-8b`, `baai/bge-m3`, `amazon/titan-embed-text-v2` | `google/gemini-embedding-*`, Cohere, Voyage |
| Images | `microsoft/mai-image-2.7-flash` | Google Gemini Image, `openai/gpt-image-*` |
| Read-aloud | `microsoft/mai-voice-2.1-flash` | – |
| Dictation | `openai/whisper-large-v3-turbo` | – |

A model without a ZDR endpoint shows up as *"ZDR violation (guardrail)"* or *"No endpoints found matching your data policy"*. Then choose another model under *Admin → Family & AI*. The selection lists there show all models and do not filter by ZDR.

### 5. Test afterwards

After any change to the guardrail or models, test once: a chat with web search, an image, read-aloud, dictation and a document upload. You see immediately whether a model is blocked.

## Limits – stated honestly

- **Processing happens at US companies.** OpenRouter is US-based, and the models from Anthropic, OpenAI or Microsoft run at those providers. ZDR means "not stored", not "stays in the EU". That an endpoint really stores nothing rests on the provider's promise and OpenRouter's classification, not on an audit of our own.
- **EU region:** `eu.openrouter.ai` and the "Europe" region in the guardrail exist only on the Business or Enterprise plan, and there web search and server tools are unavailable. For a family that is usually not practical. If you need "EU only", use an EU-hosted provider or local models (currently not part of the app).
- **Web search:** ZDR applies to the model request. How long the search provider keeps the query is up to its own policy. For the strictest setup, turn off the “Web search” switch for the children (*Admin → People*).
- **Memory:** memory entries are part of the system prompt and go to the model. For children, the “Memory” switch in *Admin → People* can be turned off per person.
- **Local is not automatically safe:** protection depends on your network, the Mac login and the family's passwords. Use HTTPS and ideally a VPN, enable “Admin only from home network/VPN” (*Admin → Family & AI*), and check the access rights of the backups.

## If you notice something

The source is open. Please report bugs or suggestions as an issue in the repository.
