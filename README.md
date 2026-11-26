# ギター運指の最適化とタブ譜生成

単音のMIDIメロディから、標準チューニングの6弦ギターで使う弦、フレット、左手の指を選び、テキストのタブ譜にします。卒業研究で作成した混合整数最適化モデルは、手のポジション移動、弦移動、指の広がり、押弦、開放弦の使用に重みを付けて運指を評価します。

## サンプルを試す

リポジトリのルートで実行します。Python 3.10以上が必要です。

```sh
python -m pip install -r requirements.txt
python -m guitar_tab prepare examples/demo.mid -o outputs/demo.dat
python -m guitar_tab tab outputs/demo.dat examples/demo-fingerings.txt
```

`demo.mid` は4音と1休符のサンプルです。同梱の `demo-fingerings.txt` にCPLEXで求めた運指表があるので、この手順はPythonだけで実行できます。

```text
Rhythm: q---e---e(R)-e---q---
      e|---------------------
      B|---------------------
      G|---------------------
      D|---------------------
      A|-----------------0---
      E|0---1--------3-------
Finger: 0---1--------2---0---
```

## CPLEXで運指を最適化する

IBM ILOG CPLEX Optimization Studioの `oplrun` を `PATH` に追加します。実行ファイルは `--oplrun` または環境変数 `OPLRUN` でも指定できます。モデルの規模によってはCommunity Editionの変数・制約数の上限を超えます。[oplrunの概要](https://www.ibm.com/docs/en/icos/22.1.1?topic=interface-description-oplrun) · [CPLEXのエディション](https://www.ibm.com/products/ilog-cplex-optimization-studio)

```sh
python -m guitar_tab solve outputs/demo.dat -o outputs/demo.log
python -m guitar_tab tab outputs/demo.dat outputs/demo.log -o outputs/demo-tab.txt
```

- `prepare` は最初に発音イベントを含むトラックを変換します。`--track` で1始まりのトラック番号を指定できます。テンポは検出した最後のテンポを曲全体に適用し、テンポ情報がなければ120 BPMを使います。`--bpm` で上書きできます。対象音域はMIDI番号40〜86（E2〜D6）です。
- `solve` は既定で [`models/modified_model.mod`](models/modified_model.mod) を実行します。`--model` で別のOPLモデルを指定できます。実行ログはエラー時も確認できます。
- `tab` は最適化に使った `.dat` とログの運指表を読み込みます。`sN` はフレットNへのスライド、`(R)` は休符、`?` は近い音価に分類できなかった区間です。旧データで音価の記録がない場合は `availableTime` から近似します。

ギターや手の寸法、コストの重みは [`config/optimization.dat`](config/optimization.dat) にあります。変更した設定ファイルを `prepare --config` に渡せます。既定値は弦移動コスト（SC）を使い、手首角度の変化に対するコスト（AT）をゼロにした実験データに合わせています。各コマンドの引数は `python -m guitar_tab <コマンド> --help` で確認できます。出力先には新しいファイル名を指定してください。

新規生成する `.dat` の `availableTime[i]` には、イベント `i` の直後の移動時間を格納します。音価は `Duration ms` コメントに記録します。この補正により、同じMIDIを使っても旧Notebookで生成したデータと最適化結果が変わる場合があります。

## 研究時のファイル

[`research/`](research/) に分析Notebookと比較用のOPLモデルを保存しています。分析Notebookが参照する当時のMIDI、データ、ログは [整理前のコミット](https://github.com/funno0223/bachelor_code/tree/01f76791f99f0ac59265a502b7c9c259c415b4e7) にあります。当時の構成を再現するには、そのコミットを別の作業ディレクトリに展開してください。

```sh
git worktree add --detach ../bachelor_code-research 01f76791f99f0ac59265a502b7c9c259c415b4e7
```

Python側のテストは `python -m unittest discover -s tests` で実行できます。
