# フェード修正の一時停止記録 — 2026-09-08

実利用枠は開始時13％、最終確認で残量10％（usedPercent 90）。ユーザー指定の停止条件に達したため停止。自動再開・使用量リセットは行わない。試験プロセスは終了済み、Lunaも停止確認済み。

## 完了

- 本体とテストの該当箇所だけ確認。追加API調査はしていない。
- `tests/integration.lua` を修正。呼出元の合成状態を SRCALPHA / INVSRCALPHA にし、本体のプリマルチプライドα用指定漏れを隠さないようにした。
- 白の色ソースを追加し、黄色背景上の開始・終了フェードでR/Gが255を維持する検査を追加。元PNGの透明部分・半透明部分の黄色背景への合成検査も追加。既存の透明背景検査・解放手順は維持。
- **修正前の本体で再現成功**。`GPU white over yellow RG half` の失敗を確認。試験の終了コードは1、wrapperは2（期待した検査失敗であり、合格ではない）。
- ログ: `verification/guarded-runs/20260908-002710-1788794830749136000/child.log`
- `ambient-source-events.lua` は未変更。修正前コピーは `/private/tmp/ase-before-fade-fix.lua`。
- 既存OBS・OBS設定は変更していない。

## 未完了・再開手順

1. 実際の利用枠を取得。残量10％以下または取得不可なら停止を維持。
2. Lunaに本体の最小修正だけ依頼。`video_render` の filter_begin 成功後、filter_endによる描画を `gs_blend_state_push` → `gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA)` → 描画 → `gs_blend_state_pop` で囲む。RGBとαへのopacity乗算は維持。
3. `tests/unit.lua` はGPUを模擬しているため、新たなblend関数3種も模擬対象へ追加して実GPU関数を呼ばないようにする。
4. Astraが差分を確認し、同じ試験を実行する。`/opt/homebrew/bin/python3.11 tests/run_guarded.py --timeout 35 tests/integration.lua --graphics --modules --audio --seconds 25`。開始・終了フェード、透明部分、後続の無効化検査、正常終了まで確認。修正後の試験はまだ未実施。
5. 本体修正後のunit試験も必要範囲で確認。結果をREADMEと受入記録へ反映。独立GPU試験とユーザーの実OBS画面確認は区別する。

各作業単位の区切りで利用枠を確認し、残量10％以下で新規処理・委任を止める。追加機能・無関係な変更・重複調査・不要な並列実行は禁止。
