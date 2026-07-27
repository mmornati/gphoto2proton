# Addendum — gphoto2proton Product Brief

## Competitive Comparison

| Solution | Streaming | EXIF Fix | Album Recreation | Proton Upload | macOS/Linux |
|---|---|---|---|---|---|
| **gphoto2proton** (planned) | ✅ tar-fs streaming | ✅ exiftool | ✅ Planned | ✅ Planned | ✅ Native |
| **rclone** | ❌ Full extract | ❌ | ❌ (API limit) | ⚠️ Beta, Photos folder issues | ✅ |
| **google-photos-takeout-helper** | ❌ | ✅ Timestamps only | ❌ | ❌ | ✅ |
| **CloudsLinker** | ❌ | ❌ | ❌ | ✅ | ✅ |
| **Blober** | ❌ (direct API) | ❌ | ❌ | ❌ (files only) | ✅ |
| **Bash script (theccres)** | ❌ | ⚠️ Basic | ❌ | ❌ | macOS only |

## Key Risks

- **Existential**: Proton ships native cross-platform import — mitigation: open-source community lock-in and power-user CLI features Proton won't build.
- **API instability**: Proton Drive SDK (June 2026) available at ProtonDriveApps/sdk — use it to reduce reverse-engineering risk.
- **Niche market**: narrow intersection but growing rapidly (100M Proton users, doubled in 18mo).

## Recommended Go-to-Market

1. Ship working MVP to GitHub
2. Post to r/ProtonDrive, r/privacy, r/DataHoarder
3. Engage Proton UserVoice community
4. Write migration-guide blog posts
5. Target Immich and rclone communities

Full market research: `_bmad-output/planning-artifacts/research/market-gphoto2proton-research-2026-07-27.md`
