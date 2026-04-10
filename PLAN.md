# monGARS — On-Device Bilingual AI Assistant



**monGARS — Revised Plan**







**Overview**





Build monGARS, a fully native iOS on-device agentic assistant powered by Core ML. It is bilingual in English (Canada) and French (Canada), privacy-first, and local-first. The first deliverable focuses on a working chat UI, guided model download, and real on-device inference pipeline.









**Product Principles**





- Native iOS only: Swift + SwiftUI
- On-device first: core chat, memory, and voice run locally after model download
- Privacy-first: user data stays on device unless a specific network-based tool is explicitly used
- Bilingual by design: en-CA and fr-CA across UI, voice, prompts, and responses
- Progressive delivery: prove inference and UX first, then expand agent/tool depth











**Model Strategy**







**Default model path**





- Primary default model: Llama 3.2 1B Instruct via Core ML  
Chosen for broader device compatibility, lower memory pressure, and faster first-deliverable success







**Enhanced model path**





- Enhanced model on stronger devices: Llama 3.2 3B Instruct via Core ML  
Used on supported newer devices where performance and memory are acceptable







**Embeddings**





- Embedding model: Granite Embedding 278M Multilingual via Core ML  
Used for semantic memory, retrieval, and bilingual recall











**First Deliverable Scope**





The first deliverable must include:



- Guided onboarding with explicit model download consent
- Model download manager with progress, pause/resume, storage estimate, and delete/re-download
- Working local chat UI
- Real on-device inference pipeline
- Streaming assistant responses
- Persistent conversation history saved locally
- Bilingual UI and assistant response support for en-CA / fr-CA
- Voice input using iOS Speech framework
- Text-to-speech in both supported locales
- Settings screen for language, model management, and privacy controls
- One minimal approval-gated tool flow
- Sensitive action confirmation UI





The first deliverable must not try to fully complete the entire long-term agent platform in one pass.









**What Works Fully On-Device**





After models are downloaded, these core capabilities work locally:



- chat
- conversation history
- speech input/output
- prompt handling
- local memory
- local inference
- local settings and privacy controls





Some future tools may require network access, such as:



- weather
- web search
- remote APIs
- cloud sync





Those are not part of the core offline claim.









**Bilingual Behaviour Rules**





monGARS must:



- support English (Canada) and French (Canada)
- preserve the user’s current language by default
- switch languages only when requested or clearly implied
- prefer natural Canadian French, not France French, when speaking French
- use en-CA and fr-CA for:  

  - UI strings
  - speech recognition
  - text-to-speech
  - prompt compilation
  - assistant responses
  - message metadata where useful
- 











**First Tool Scope**





For the first deliverable, the tool system should stay narrow and real.





**Initial approved tool set**





- Create reminder / note
- Conversation search
- Copy / share response
- Optional: create calendar event with approval







**Not first-deliverable priorities**





- full weather integration
- broad web tools
- deep multi-tool autonomous orchestration
- large cross-app control surface





These can come later once the core inference loop is stable.









**Features**







**Core V1 features**





- Chat with an on-device AI model using Core ML
- Guided first-launch model download with progress and storage controls
- Bilingual support across UI, speech, and AI responses
- Local persistent conversation history
- Voice input via iOS Speech framework (en-CA, fr-CA)
- Text-to-speech responses in both languages
- Minimal typed tool-calling foundation
- User confirmation for sensitive actions
- Settings for model, language, and privacy management







**Phase 2+ features**





- Semantic memory using Granite multilingual embeddings
- Broader typed tool system
- Agent orchestration loop
- richer retrieval and summarisation
- more device integrations and automations











**Design**





- System-native iOS aesthetic
- automatic light/dark mode
- Apple-quality visual language using semantic colors and SF typography
- Chat UI inspired by iMessage
- smooth animations, typing state, and subtle haptics
- bottom input bar with voice toggle
- onboarding flow for guided model download
- settings screen for language, model storage, and privacy
- approval sheet for sensitive actions











**Screens**







**1. Onboarding / Model Setup**





- explains on-device privacy
- asks for model download consent
- shows storage estimate
- shows progress, pause/resume, and download state







**2. Chat**





- main conversation interface
- message bubbles
- streaming response state
- voice input button
- send bar
- typing / generation indicator







**3. Conversations List**





- local conversation history
- search
- timestamps
- swipe-to-delete







**4. Settings**





- language preference (en-CA / fr-CA)
- model management
- storage used
- delete / re-download
- privacy controls
- voice settings







**5. Tool Approval Sheet**





- confirmation before sensitive actions
- clear explanation of what the assistant wants to do











**Architecture Modules**







**App**





- app entry point
- dependency container
- navigation routing







**AI / LLM**





- Core ML model loading
- tokenizer boundary
- text generation pipeline
- streaming output







**AI / Embeddings**





- Granite embedding model
- vector computation
- retrieval boundary







**AI / Agent**





- response assembly
- minimal orchestration boundary
- approval-aware action planning hooks







**Features / Chat**





- chat UI
- message models
- conversation view models
- history integration







**Features / Voice**





- speech recognition
- text-to-speech
- locale-aware voice handling







**Tools**





- typed tool definitions
- schemas
- execution boundary
- approval flow







**Data**





- SwiftData for conversations, messages, preferences
- SQLite for embeddings and vector storage







**Services**





- model download manager
- permissions manager
- locale manager
- privacy/safety manager







**Resources**





- localized strings
- prompt templates
- model metadata











**Persistence Strategy**





Use a hybrid persistence model:



- SwiftData for:  

  - conversations
  - messages
  - user preferences
  - approval history
  - app state
- 
- SQLite for:  

  - embedding vectors
  - semantic chunks
  - retrieval indexing
  - tighter control over search performance
- 





This keeps the app Apple-native where it helps, and low-level where control matters.









**Delivery Sequence**







**Phase 1**





- onboarding
- model download
- local chat UI
- inference pipeline
- conversation persistence
- bilingual UI and language handling
- speech input/output
- settings
- minimal approval-gated tool







**Phase 2**





- embeddings
- semantic retrieval
- memory ranking
- conversation summarisation







**Phase 3**





- broader typed tools
- stronger agent loop
- richer approvals and safety policies







**Phase 4**





- automation surfaces
- shortcuts
- widgets
- deeper device integrations within iOS limits











**App Icon Direction**





- clean stylized brain / neural network motif
- modern, geometric, minimal
- privacy + intelligence feel
- system-blue accent on light background
- strong legibility at small sizes











**Final Approval Version**





Approved plan:

Build monGARS as a native iOS on-device assistant with guided model download, working local chat, bilingual en-CA / fr-CA support, voice input/output, local persistence, and a real inference pipeline as the first deliverable. Use Llama 3.2 1B as the default path, Llama 3.2 3B as the enhanced path for stronger devices, and Granite 278M multilingual embeddings for later semantic memory and retrieval. Use a hybrid persistence strategy with SwiftData + SQLite. Keep the first release focused, real, and stable.