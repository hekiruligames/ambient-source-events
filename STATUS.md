# Ambient Source Events 現在地

## 現在の開発段階

初版機能とFade、Peek、Wipe、Zoomの基本エフェクトは完成・検証済みです。現在は、既存機能を壊さないよう拡張機能を1つずつ追加・検証している段階です。4エフェクト共通のイージング基本機能、WipeのSoftness、Zoom倍率UI、Media Source非表示境界の1フレーム混入修正、固定間隔0秒のPersistent Source境界修正は、自動試験・実OBS確認ともに合格しました。Zoom倍率UIは通常step 0.1%・高倍率step 10%の最終仕様です。

## 完成済み

- 初版機能：定期表示、時間管理、Media / Persistent制御、非表示中の消音、復元・終了処理
- Fade：透明度だけを変化させる
- Peek：映像内容だけを移動させる
- Wipe：映像内容を移動させず、表示境界だけを進行させる
- Wipe Softness：0〜100%、ソース高さ基準の境界幅、開始・終了独立。終端連続性修正を含め自動試験・実OBS目視確認PASS
- Zoom：拡大縮小だけを担当する基本エフェクト
- Zoom倍率UI：通常は0〜500%・step 0.1%のOBS標準スライダー一つ。開始／終了独立のチェックでstep 10%の高倍率数値入力へ切替。自動試験・実OBS目視確認PASS
- Media Source非表示境界：新しい再生世代を再生位置の前進まで非表示で確認し、終了時の再生位置逆行を`ENDED`通知前に検出して非表示へ移行。自動試験・実OBS目視確認PASS
- 固定間隔0秒のPersistent Source境界：終了後の完全非表示フレームを挟まず、同一tick内で次イベントを最大1回開始。自動試験・実OBS録画確認PASS
- イージング基本機能：開始・終了で独立したLinear / Cubic Ease In / Ease Out / Ease In-Out

## 実装方針

拡張機能も1回に1つだけ実装します。複合効果はまだ混ぜません。

## 参照先

- 詳細仕様：`PLAN.md`
- 検証済み事項：`verification/ACCEPTANCE.md`
- 過去のhandoffや個別ログ：問題調査が必要な場合のみ参照
