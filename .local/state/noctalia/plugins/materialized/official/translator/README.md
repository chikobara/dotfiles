# Translator

Translator adds a launcher provider that translates text through Google
Translate or DeepL and copies the selected result to the clipboard.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/translator` |
| Entry | Launcher provider: `translate` |
| Launcher Prefix | `/tr` |

## Usage

Open the Noctalia launcher and type `/tr`, followed by an optional target
language and the text to translate.

```text
/tr es hello world
/tr french good morning
/tr hello world
```

When the first word is a known language name, alias, or two- to three-letter
language code, it is used as the target language. Otherwise the plugin uses the
configured `target_lang`. If the provider rejects that first word as a language,
the whole query is translated once more against `target_lang`, and the result
row says which word was treated as text. Press Enter on a translation result to
copy it to the clipboard.

## Requirements

Depending on the configured provider, this plugin requires network access to
either `translate.googleapis.com` (for Google Translate via the
`translate_a/single` endpoint) or `api.deepl.com` / `api-free.deepl.com` (for
DeepL via the `v2/translate` endpoint). DeepL free-tier keys end in `:fx` and
automatically select the free endpoint.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `target_lang` | `string` | `en` | Default target language code when the query does not include one. |
| `provider` | `select` | `google` | The translation service to use (`google` or `deepl`). |
| `deepl_api_key` | `string` | `""` | Your DeepL API Key (only required if you choose to use DeepL). |

## Notes

Results are cached in memory for the current plugin session, and duplicate
in-flight requests are coalesced while typing.
