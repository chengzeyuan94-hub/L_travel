# Public release cleanup · 0.2.4-public.1

## 2026-10-19: separately downloadable functional rules

At the project maintainer's explicit request, `rules/LTravel-functional-rules-v1.json` now supplies the r2 baseline's functional exchange values, goods supplies, starting grants and 36 machine-readable event effects. Event titles and instructions are newly written. The JSON uses the already bundled board and excludes original card images, scans, original prose, private maps and third-party character assets. Existing v2 additional-city parameters are retained unchanged; this is not a balance certification or a claim of the tabletop author's authorization. The code MIT and project-owned asset licenses do not automatically grant rights in third-party data, text, artwork or arrangement.

The installation packages and frozen tag are unchanged. The following records the original package cleanup, not the content of this later optional JSON. See [import instructions](rules/IMPORT-RULES.md).

## Original package cleanup

The independent release copy is based on the accepted map-workshop **0.2.4-r2** assembly dated 2026-10-10, with the required generated traveler atlas restored from the local production source. The unaccepted r4 GUI candidate, old main-branch snapshot and prior postcard-unlock packages are not this release's baseline. Private originals and the existing remote initial commit were preserved.

Removed from public source, history and packages:

- Physical-board scans, photographs, original card pictures and verbatim event effects; original 80-card transcription and duplicate fixtures/reports/archives. Eight original trade deck containers now have empty card arrays; event definitions and instances are empty.
- Original card-fitted v1 parameters, original supply counts and starting grants. The existing configurable v2 implementation remains. It is the project's additional-city generator, not the tabletop creator's official formula; no replacement balance or default policy has been invented.
- Gundam, Going Merry, specific-work-styled Wukong/cloud, Wakanda/Vibranium private assets and examples, including their embedded models, thumbnails and generated card data. The private 18-city planning map is not in this release.
- Unknown-source standalone music and ambient audio, including its derived theme-generation source. Public sound effects are newly generated silence placeholders. **This does not make the package silent:** four retained traveler intro OGVs contain non-silent embedded Vorbis tracks and the normal player may restore their volume. Separate provenance/licensing evidence for those final mixes is still unresolved; the general visual-production attribution is not proof of audio rights. No video has been removed or repackaged in this documentation correction. See VERSIONING.md for the current known limits.
- External raw animation accessors/buffer data in eight GLBs, sampled motion reports and related reconstruction inputs. Two inline character scenes now use independent procedural motion. Mesh/image/skin streams were compared with the private input and preserved; the public movement is visibly simpler than the private version.
- Old archives, reports, transcription tools, copied rule ledgers, private signing credentials, caches, saves and old Git history. The only history imported is the target repository's pre-existing initial README commit.

Retained: project code, configurable schemas/seed/validation, project-created city artwork and educational geography text, 3D scenery, ordinary camel/boat pieces, editor/save/import workflows, and the atlas needed by all four travel acts. Geography names and generic mechanics remain available; their presence is not a claim of official tabletop authorization. The public rule namespace is lshu_configurable_v1. A complete owner-confirmed configuration is required for formal play and trial; editing/saving drafts works before configuration.

All four travel acts are open without wins. Generic camel/boat pieces have no extra unlock. Unlocking does not alter currency balances. User-imported old maps may still embed original deck data or third-party IP; do not redistribute those maps merely because the program accepts them.

Release audit includes file hashes, embedded GLB images, semantic original-card row matching, original event-text matching, archive/file-type checks, credential patterns and exported-resource inventory. Automated matching does not prove every possible derivative is absent. Provenance was reviewed by asset family and recorded per asset in ASSET_LICENSES.csv. Cleanup is a concrete scope record, not legal immunity.
