# OpenAI Audio model discovery

- 2026-09-05: Reused the provider's `/models` request and model picker for
  OpenAI Audio. TTS model is selected from fetched results instead of typing.
  Filter uses the explicitly documented Speech endpoint models; transcription,
  Realtime and generic audio models are excluded. Empty/error responses retain
  the saved choice, and a changed URL/protocol invalidates a pending result.
- Reference: https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create
- Validation: four targeted service/UI tests passed (filtering, empty/error
  responses, Audio visibility and fetched choice persistence without changing
  the chat model). Static analysis passed. Tests use mocked HTTP; no live
  account requests or speech generation were performed.
