/*********************************************
 * OPL 22.1.1.0 Model
 * Author: funno
 * Modified: Unified Logic & Slant Model (Updated v19)
 * Final Fix: Pre-calculated Flags & Static Filtering
 *********************************************/

using CPLEX;

// ============================================================================
// 1. データ定義 & パラメータ
// ============================================================================

int RestNote = 0;

int f_max = ...;
int s_max = ...;
int p_max = ...;

range Frets = 0..f_max; 
range Strings = 1..s_max;

{int} PlayableSounds = ...;
tuple combination {
  int corda;
  int fret;
}

{combination} AllCombinations = {<s,f> | s in Strings, f in Frets};
{int} OpenStrings[PlayableSounds] = ...;
{combination} Combinations[PlayableSounds] = ...;

string MidiNames[0..127] = ...;

int m = ...;
range Notes = 1..m;
range NotesButFirst = 2..m;
int note[Notes] = ...;
float availableTime[Notes] = ...;

range Fingers = 1..4;
range FingersButFirst = 2..4;
range HandPosition = 1..p_max;

// --- パラメータ群 ---

float scaleLength = ...;
float fretPosition[Frets];
float stringSpacing = ...;
float SP_max_mm[FingersButFirst] = ...;
float fingerLengths_mm[Fingers] = ...;
float fingerDifficulty[Fingers] = ...;
float timeThresholdRatio = ...;
float highPositionPenalty = ...;
float natural_min_spread_mm[FingersButFirst] = ...;

// --- 回転モデル用パラメータ ---
float knuckleOffsets[Fingers] = [0.0, 20.0, 40.0, 60.0];
// maxRotationAngle は execute ブロック内で動的に計算するためここでは固定値としては使いません

// 計算テーブル
float Stretch_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];
float Physics_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];

// 既存のパラメータに加えて使用
float rad_to_deg = 180.0 / 3.141592653589793;
float deg_to_rad = 3.141592653589793 / 180.0;


// コスト係数
float d_PC = ...;
float d_SC = ...;
float d_ST = ...;
float d_DH = ...;
float d_NO = ...;

float alpha_PC = ...;
float alpha_SC = ...;
float alpha_ST = ...;
float alpha_DH = ...;
float alpha_NO = ...;

// ============================================================================
// 2. 前処理 (Execute Blocks)
// ============================================================================

// A. フレット位置計算
execute {
  for (var f in Frets) {
    fretPosition[f] = scaleLength - (scaleLength / Math.pow(2, f / 12.0));
  }
}

// ============================================================================
// B & C ストレッチ(Stretch) と 物理負荷(Physics) の独立計算
// ============================================================================
execute {
  var PI = 3.141592653589793;
  var knuckleDist = new Array();
  knuckleDist[1] = 0.0;
  for(var f=2; f<=4; f++) {
     knuckleDist[f] = natural_min_spread_mm[f];
  }
  
  var limitRatios = new Array();
  limitRatios[1] = 1.0; limitRatios[2] = 1.05; limitRatios[3] = 1.05; limitRatios[4] = 1.2; 
  
  // 変更: 有効指長係数 (Index:0.9, Middle:0.9, Ring:0.8, Pinky:1.0)
  var baseFactors = new Array();
  baseFactors[1] = 0.9; baseFactors[2] = 0.9; baseFactors[3] = 0.8; baseFactors[4] = 1.0;

  // 物理モデル用定数
  var stringTension = new Array();
  stringTension[1] = 1.0; stringTension[2] = 1.0; stringTension[3] = 1.0;
  stringTension[4] = 1.2; stringTension[5] = 1.4; stringTension[6] = 1.6;
  
  var breakAngleDeg = 15.0; 
  var tanTheta = Math.tan(breakAngleDeg * deg_to_rad);

  writeln("INFO: Calculating Separated Costs (Stretch vs Physics)...");

  for(var p in HandPosition) {
    var pivotX = fretPosition[p];
    var pivotY = 0.0; 

    for(var h in Fingers) { 
      for(var c in AllCombinations) {
        
        // --- 初期化 ---
        Stretch_CostTable[p][h][c] = 0.0;
        Physics_CostTable[p][h][c] = 0.0;

        // 0. 論理的制約 (ハード制約用フラグ)
        if (c.fret < p) {
             Stretch_CostTable[p][h][c] = 100000.0;
             continue; // Physics計算不要
        }

        // =================================================
        // 特徴量1: 幾何学コスト (Stretch)
        // =================================================
        var targetString = c.corda;
        
        // 変更: 最大回転角 45.0 -> 40.0
        var maxRotation = 40.0; 
        
        // 基本回転角 (弦依存: 6弦->0度, 1弦->-40度)
        var baseTheta = maxRotation * (targetString - 6.0) / 5.0; 
        
        // 変更: フレット依存の追加回転 (弦による重み付けを追加)
        // 1. そのフレットでの最大追加回転角 (17フレットで15度)
        var fretRotationMax = (c.fret / 17.0) * 15.0;
        
        // 2. 弦による係数 (1弦=0.0, 6弦=1.0)
        var stringFactor = (targetString - 1.0) / 5.0;
        
        // 3. 最終的な追加回転角
        var fretRotation = fretRotationMax * stringFactor;
        
        // 最終的な回転角 (基本角 - 追加角)
        var thetaDeg = baseTheta - fretRotation; 
        var thetaRad = thetaDeg * deg_to_rad;

        var d = knuckleDist[h];
        var kX = pivotX + (d * Math.cos(thetaRad));
        var kY = pivotY + (d * Math.sin(thetaRad));

        var tX = fretPosition[c.fret];
        var tY = (c.corda - 1) * stringSpacing; 

        var vX = tX - kX;
        var vY = tY - kY;
        var dist = Math.sqrt(vX*vX + vY*vY);

        var nX = -Math.sin(thetaRad);
        var nY = Math.cos(thetaRad);

        // 有効長と限界判定
        var neckFactor = 1.0;
        if (c.fret >= 15) {
            var ratioHigh = (c.fret - 15.0) / (f_max - 15.0);
            if (ratioHigh > 1.0) ratioHigh = 1.0;
            neckFactor = 1.0 - (0.15 * ratioHigh);
        }
        var effLen = fingerLengths_mm[h] * baseFactors[h] * neckFactor;

        if (effLen > 0 && dist > effLen * limitRatios[h]) {
             Stretch_CostTable[p][h][c] = 100000.0; // Impossible
             continue;
        }

        // 距離コスト
        var distCost = 0.0;
        if (effLen > 0) {
            var ratio = dist / effLen;
            if (ratio < 0.3) {
                distCost = (0.3 - ratio) * 5.0;
            } 
            // 変更: 閾値を 0.7 -> 0.6 に変更
            else if (ratio <= 0.6) {
                distCost = 0.0;
            } 
            else {
                // 変更: 閾値を 0.7 -> 0.6 に変更
                distCost = (ratio - 0.6) * 10.0;
                if (ratio > 1.0) {
                    distCost += (ratio - 1.0) * 20.0;
                }
            }
        }

        // 角度コスト
        var angleCost = 0.0;
        var dotProd = vX * nX + vY * nY;
        var cosDelta = (dist > 0.001) ? (dotProd / dist) : 1.0;
        if (cosDelta > 1.0) cosDelta = 1.0;
        if (cosDelta < -1.0) cosDelta = -1.0;
        var deltaDeg = Math.acos(cosDelta) * rad_to_deg;

        // 変更: 許容角度を10度狭める (Other: 25->15, Pinky: 30->20)
        var baseMaxAngle = 15.0;
        if (h == 4) baseMaxAngle = 20.0;
        
        var maxAngle = baseMaxAngle;
        if (c.fret >= 12) maxAngle = Math.max(10.0, baseMaxAngle - (c.fret - 12) * 0.5);

        if (deltaDeg > maxAngle) {
            angleCost = (deltaDeg - maxAngle) * 0.5;
        }

        // Stretchテーブル格納
        // 変更: 難易度(diff)の乗算を除外 (単純和)
        // var diff = fingerDifficulty[h]; は Physics でのみ使用
        Stretch_CostTable[p][h][c] = distCost + angleCost;

        // =================================================
        // 特徴量2: 物理アクションコスト (Physics)
        // =================================================
        // Grimes Model: F ~ tau * a / l
        
        var a_mm = 0.5 + (2.0 * c.fret / 12.0); // Action
        var l_mm = scaleLength - fretPosition[c.fret]; // Vibrating Length
        var tau = stringTension[targetString]; // Tension

        // l_mm が 0 になるケースのガード（理論上はないはずだが念のため）
        var forceIndex = 0.0;
        if (l_mm > 0.001) {
             forceIndex = (2.0 * tau * a_mm) / (l_mm * tanTheta);
        }

        // 指難易度は物理コストにも影響する (小指は力が弱いのでコスト増)
        var diff = fingerDifficulty[h];
        // Scaling: 係数 200.0
        Physics_CostTable[p][h][c] = (forceIndex * 100.0) * diff;
      }
    }
  }
  writeln("INFO: Separated Cost Tables Generated.");
}

// ----------------------------------------------------------------------------
// D. 時間変数と判定フラグの計算
// ----------------------------------------------------------------------------
int prevNoteIndex[Notes];
float accumulatedTime[Notes];

// 判定フラグ配列 (0=False, 1=True)
int isFast[Notes];   
int isLegato[Notes]; 

execute {
  for (var i = 2; i <= m; i++) {
    if (note[i] != RestNote) {
       var p = i - 1;
       var timeSum = 0.0;
       
       while (p >= 1 && note[p] == RestNote) {
         timeSum += availableTime[p];
         p--;
       }
       
       if (p >= 1) {
         prevNoteIndex[i] = p;
         accumulatedTime[i] = timeSum + availableTime[p];
       } else {
         prevNoteIndex[i] = i;
         accumulatedTime[i] = 10000.0;
       }
    } else {
       accumulatedTime[i] = 0.0;
    }
  }
  
  var maxDist = Math.abs(fretPosition[0] - fretPosition[f_max]);
  var timeForMaxSlide = maxDist * timePerMm;
  var relaxThreshold = timeForMaxSlide * 1.5; 
  var legatoThreshold = 50.0;                 
  
  writeln("INFO: Time Logic Initialized.");
  writeln("  - Relax Threshold: ", relaxThreshold, " ms");
  
  for (var j = 1; j <= m; j++) {
     if (accumulatedTime[j] < relaxThreshold) {
        isFast[j] = 1;
     }
     if (accumulatedTime[j] <= legatoThreshold) {
        isLegato[j] = 1;
     }
  }
}

// ============================================================================
// 3. 変数・目的関数
// ============================================================================

dvar boolean o[Notes][Strings];
dvar boolean y[Notes][HandPosition][Fingers][AllCombinations];
dvar boolean x[Notes][HandPosition];

// PC
dexpr float PC[i in NotesButFirst] = 
  (note[i] == RestNote) ? 0.0 : 
  (prevNoteIndex[i] == i) ? 0.0 : 
  abs(sum(p in HandPosition) fretPosition[p] * x[prevNoteIndex[i]][p] - 
      sum(p in HandPosition) fretPosition[p] * x[i][p]);

// SC
dexpr float SC[i in NotesButFirst] = 
  (note[i] == RestNote) ? 0.0 : 
  (prevNoteIndex[i] == i) ? 0.0 :
  stringSpacing * abs(
    ( sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) c.corda * y[prevNoteIndex[i]][p][h][c] +
      sum(s in Strings : s in OpenStrings[note[prevNoteIndex[i]]]) s * o[prevNoteIndex[i]][s]) 
      - 
    ( sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) c.corda * y[i][p][h][c] +
      sum(s in Strings : s in OpenStrings[note[i]]) s * o[i][s])
  );

float jointDiscountRate = 0.9; 
dexpr float JointSavings[i in NotesButFirst] = 0.0;
 /* (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 :
  sum(p in HandPosition)
  sum(h in Fingers : h == 1) // 人差し指のみ
  sum(c in Combinations[note[i]])
  sum(c_prev in Combinations[note[prevNoteIndex[i]]] : 
      c.fret == c_prev.fret && abs(c.corda - c_prev.corda) >= 1)
    (stringSpacing * jointDiscountRate) * y[i][p][h][c] * y[prevNoteIndex[i]][p][h][c_prev];
*/
// ST (Stretch Cost)
dexpr float ST[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(p in HandPosition) 
  sum(h in Fingers) 
  sum(c in Combinations[note[i]])
    Stretch_CostTable[p][h][c] * y[i][p][h][c];

// DH (Physics/Action Cost)
dexpr float DH[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(p in HandPosition) 
  sum(h in Fingers) 
  sum(c in Combinations[note[i]])
    Physics_CostTable[p][h][c] * y[i][p][h][c];

// 時間係数
dexpr float timePenaltyFactor[i in NotesButFirst] = 
  (note[i] == RestNote) ? 0.0 : 
  minl(1.0, 50.0 / (accumulatedTime[i] + 0.01)); 

dexpr float tot_PC = sum(i in NotesButFirst) PC[i] * timePenaltyFactor[i];
dexpr float tot_SC = sum(i in NotesButFirst) SC[i] * timePenaltyFactor[i];
dexpr float tot_JointSavings = sum(i in NotesButFirst) JointSavings[i] * timePenaltyFactor[i];
dexpr float tot_ST = sum(i in Notes) ST[i];
dexpr float tot_DH = sum(i in Notes) DH[i];
dexpr float tot_NO = sum(i in Notes) sum(s in Strings : s in OpenStrings[note[i]]) o[i][s];

minimize
  alpha_PC * d_PC * tot_PC +
  alpha_SC * d_SC * (tot_SC - tot_JointSavings) + 
  alpha_ST * d_ST * tot_ST + 
  alpha_DH * d_DH * tot_DH +
  alpha_NO * d_NO * tot_NO;

// ============================================================================
// 4. 制約条件 (Constraints)
// ============================================================================

subject to {
  // --- 基本整合性 ---
  forall(i in Notes) {
    vinc2:
      sum(s in Strings : s in OpenStrings[note[i]]) o[i][s] +
      sum(p in HandPosition) sum(h in Fingers) sum(c in Combinations[note[i]]) y[i][p][h][c] 
      == (note[i] != RestNote);

    vinc2neg:
      sum(p in HandPosition) sum(h in Fingers) 
      sum(c in AllCombinations : c not in Combinations[note[i]]) y[i][p][h][c] == 0;

    vinc3:
      sum(p in HandPosition) x[i][p] == 1;

    forall(p in HandPosition)
      vinc4:
        sum(h in Fingers) sum(c in AllCombinations) y[i][p][h][c] <= x[i][p];
  }

  forall(i in NotesButFirst)
    forall(p in HandPosition)
      vinc5:
        x[i][p] - x[i-1][p] <= 1 - sum(s in OpenStrings[note[i]]) o[i][s];

  // 物理移動制約
  forall(i in NotesButFirst) 
    vinc6_mod:
       if (note[i] != RestNote && prevNoteIndex[i] != i) 
          (PC[i] * timePerMm) <= accumulatedTime[i];

  forall(i in Notes) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
           
           // [制約 1] ポジション整合性 (論理制約)
           if (c.fret < p) {
               y[i][p][h][c] == 0;
           }

           // [制約 2] 幾何学的制約 (コストテーブル参照)
           if (Stretch_CostTable[p][h][c] >= 50000.0) {
               y[i][p][h][c] == 0;
           }
        }
      }
    }
  }

  // =========================================================================
  // 遷移制約
  // =========================================================================
  
  // --- A. ハード制約: 物理的に不可能な動き (常に適用) ---
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
           
             y[i][p][h][c] + 
               sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                   (
                     // [1] 同一指: スライド/ジョイント以外の移動禁止
                     (h == h_prev && 
                        !(
                           (c.corda == c_prev.corda) || 
                           (h != 4 && h != 3  && c.fret == c_prev.fret && abs(c.corda - c_prev.corda) == 1)
                        )
                     )
                     ||
                     // [2] クロス指: 同フレット異弦での指順序逆転禁止
                     (c.fret == c_prev.fret && c.corda != c_prev.corda && 
                        ((c.corda < c_prev.corda && h < h_prev) || (c.corda > c_prev.corda && h > h_prev)))
                     ||
                     // [3] 同弦上: フレット移動と指番号の逆転禁止
                     (c.corda == c_prev.corda && 
                        ((c.fret > c_prev.fret && h < h_prev) || (c.fret < c_prev.fret && h > h_prev)))
                   )
               ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
               <= 1;
          }
        }
      }
  }

  // --- B. ソフト制約: 速いフレーズでの制限 (isFast[i]==1 のみ適用) ---
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
               y[i][p][h][c] + 
               sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                   (
                     // 一般的な指順序の推奨
                     (c.fret > c_prev.fret && h < h_prev && c.corda != c_prev.corda) ||
                     (c.fret < c_prev.fret && h > h_prev && c.corda != c_prev.corda)
                     ||
                     // レガート制約 (isLegato[i]==1 の場合のみ追加でチェック)
                     (isLegato[i] == 1 && 
                        !(c.corda == c_prev.corda || p == p_prev) 
                     )
                   )
               ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev]
               <= 1;
          }
        }
      }
  }

} // End of subject to

// ============================================================================
// 5. 出力設定
// ============================================================================
main {
  // cplex.epgap = 0.01;
  thisOplModel.generate();
  if (cplex.solve()) {
    var obj = cplex.getObjValue();
    writeln(">>> 解が見つかりました。Objective: ", obj);
    thisOplModel.postProcess();
  } else {
    writeln(">>> 解が見つかりませんでした。");
  }
}

execute {
  writeln("Note\tString\tFret\tHandposition\tFinger");
  for (var i in Notes) {
    if (note[i] == RestNote) {
      write("R\t0\t0\t0\tx");
    } else {
      write(MidiNames[note[i]], "\t");
      var found = 0;
      var isOpen = 0;
      for(var s in Strings) if(o[i][s]==1) { write(s,"\t0\t"); isOpen=1; }
      if(isOpen==0) {
         for(var p in HandPosition) for(var h in Fingers) for(var c in AllCombinations)
            if(y[i][p][h][c]==1) write(c.corda,"\t",c.fret,"\t");
      }
      for(var p in HandPosition) if(x[i][p]==1) {
         write(p,"\t");
         if(isOpen==1) write("0");
         else {
            for(var h in Fingers) for(var c in AllCombinations) 
               if(y[i][p][h][c]==1) write(h);
         }
      }
    }
    writeln();
  }
  writeln();
  writeln("\n--- Cost Breakdown ---");
  
  // 各コスト項の計算
  var costPC = alpha_PC * d_PC * tot_PC;
  var costSC = alpha_SC * d_SC * (tot_SC - tot_JointSavings);
  var costST = alpha_ST * d_ST * tot_ST;
  var costDH = alpha_DH * d_DH * tot_DH;
  var costNO = alpha_NO * d_NO * tot_NO;

  writeln("  Position Change (PC): ", costPC);
  writeln("  String Change   (SC): ", costSC);
  writeln("  Geo Stretch     (ST): ", costST); 
  writeln("  Phys Action     (DH): ", costDH);
  writeln("  Open String     (NO): ", costNO);
  writeln("-----------------------------------------");
  writeln("  Total Cost (Sum)    : ", costPC + costSC + costST + costDH + costNO);
  writeln("-----------------------------------------");
}