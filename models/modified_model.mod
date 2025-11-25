/*********************************************
 * OPL Model for Guitar Tablature Generation
 * Modified: Added MC (Movement Cost) with Refactored Logic
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
float timePerMm = ...;
float fingerLengths_mm[Fingers] = ...;
float fingerDifficulty[Fingers] = ...;
float timeThresholdRatio = ...;
float highPositionPenalty = ...;
float natural_min_spread_mm[FingersButFirst] = ...;
// 計算テーブル
float Stretch_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];
float Physics_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];
float BestWristAngleTable[p in HandPosition][h in Fingers][c in AllCombinations];

float rad_to_deg = 180.0 / 3.141592653589793;
float deg_to_rad = 3.141592653589793 / 180.0;

// コスト係数
float d_PC = ...;
float d_SC = ...;
float d_ST = ...;
float d_DH = ...;
float d_NO = ...;
float d_MC = ...;

float alpha_PC = ...;
float alpha_SC = ...;
float alpha_ST = ...;
float alpha_DH = ...;
float alpha_NO = ...;
float alpha_MC = ...;

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
// B & C. ストレッチ(Stretch) と 物理負荷(Physics) の計算
// (v17 Logic: Neck Break 12F, Pinky Tightened, Overstretch 30, Angle -90 to 0)
// ============================================================================
execute {
  var PI = 3.141592653589793;
  
  // --- 1. ローカルパラメータ設定 ---
  
  // 指の付け根の距離 (Knuckle Distances)
  // Index(1)=0, Middle(2)=20, Ring(3)=40, Pinky(4)=55
  var knuckleDist = new Array();
  knuckleDist[1] = 0.0;  
  knuckleDist[2] = 20.0;
  knuckleDist[3] = 40.0;
  knuckleDist[4] = 55.0; 
  
  // Limit Ratios (最大伸長倍率)
  // Index=1.3, Middle/Ring=1.05, Pinky=1.1
  var limitRatios = new Array();
  limitRatios[1] = 1.3; limitRatios[2] = 1.05; limitRatios[3] = 1.05; limitRatios[4] = 1.1; 
  
  // Base Factors (有効指長係数)
  // Index=0.7, Middle=0.9, Ring=0.85, Pinky=1.0
  var baseFactors = new Array();
  baseFactors[1] = 0.7; baseFactors[2] = 0.9; baseFactors[3] = 0.85; baseFactors[4] = 1.0;

  // String Tension (Physics用)
  var stringTension = new Array();
  stringTension[1] = 1.0; stringTension[2] = 1.0; stringTension[3] = 1.0;
  stringTension[4] = 1.2; stringTension[5] = 1.4; stringTension[6] = 1.6;

  // ブリッジ折れ角
  var breakAngleDeg = 15.0;
  var tanTheta = Math.tan(breakAngleDeg * deg_to_rad);

  // ネック形状補正用の距離閾値 (12F Breakpoint)
  var dist_12 = scaleLength - (scaleLength / Math.pow(2, 12.0/12.0)); 
  var dist_max = scaleLength - (scaleLength / Math.pow(2, f_max/12.0)); 

  writeln("INFO: Calculating v17 Stretch Costs & Recording Wrist Angles...");

  for(var p in HandPosition) {
    // 基準点(Pivot)は人差し指付け根、1弦(Y=0)固定
    var pivotX = fretPosition[p];
    var pivotY = 0.0; 

    for(var h in Fingers) { 
      for(var c in AllCombinations) {
        
        // 初期化
        Stretch_CostTable[p][h][c] = 100000.0;
        Physics_CostTable[p][h][c] = 0.0;
        BestWristAngleTable[p][h][c] = 0.0; // MC計算用初期化

        // 論理的制約: 目標フレットがハンドポジションより低い場合は不可
        if (c.fret < p) continue; 

        // -------------------------------------------------------
        // 1. 物理的負荷 (Physics Cost) - 角度非依存
        // -------------------------------------------------------
        var targetString = c.corda;
        var a_mm = 0.5 + (2.0 * c.fret / 12.0); // 弦高
        var l_mm = scaleLength - fretPosition[c.fret]; // 振動弦長
        var tau = stringTension[targetString];
        var forceIndex = 0.0;
        
        if (l_mm > 0.001) {
             forceIndex = (2.0 * tau * a_mm) / (l_mm * tanTheta);
        }
        var diff = fingerDifficulty[h];
        Physics_CostTable[p][h][c] = (forceIndex * 100.0) * diff;


        // -------------------------------------------------------
        // 2. 幾何学的ストレッチ (Stretch Cost) - 角度探索
        // -------------------------------------------------------
        var minStCost = 100000.0;
        var bestAngle = 0.0;
        var foundValidAngle = 0;

        // 手首角度探索: -90度(外側/垂直) から 0度(平行) まで
        for (var ang = -90; ang <= 0; ang += 2) {
            var thetaRad = ang * deg_to_rad;
            
            // 指の付け根(Knuckle)座標計算
            var d = knuckleDist[h];
            var kX = pivotX + (d * Math.cos(thetaRad));
            var kY = pivotY + (d * Math.sin(thetaRad));

            // 目標位置(Target)座標
            var tX = fretPosition[c.fret];
            var tY = (c.corda - 1) * stringSpacing;

            // ベクトルと距離
            var vX = tX - kX;
            var vY = tY - kY;
            var dist = Math.sqrt(vX*vX + vY*vY);

            // --- Neck Factor (Piecewise at 12F) ---
            var dist_current = scaleLength - fretPosition[c.fret]; // ナットからの距離
            var neckFactor = 1.0;
            
            var reduction_at_break = 0.015; // 12Fで1.5%減
            var reduction_at_max = 0.15;    // 24Fで15%減

            if (dist_current <= dist_12) {
                // Phase 1: Nut -> 12F (緩やか)
                neckFactor = 1.0 - (reduction_at_break * (dist_current / dist_12));
            } else {
                // Phase 2: 12F -> Max (急激)
                var ratioHigh = 0.0;
                if (dist_max > dist_12) {
                    ratioHigh = (dist_current - dist_12) / (dist_max - dist_12);
                }
                if (ratioHigh > 1.0) ratioHigh = 1.0;
                neckFactor = 1.0 - (reduction_at_break + ((reduction_at_max - reduction_at_break) * ratioHigh));
            }

            // 有効指長 (Effective Length)
            var effLen = fingerLengths_mm[h] * baseFactors[h] * neckFactor;

            // 距離のハードリミット判定
            if (effLen > 0 && dist > effLen * limitRatios[h]) continue;

            // --- 角度計算 (Angle Calculation) ---
            var nX = -Math.sin(thetaRad);
            var nY = Math.cos(thetaRad);
            
            var dotProd = vX * nX + vY * nY;
            var cosDelta = (dist > 0.001) ? (dotProd / dist) : 1.0;
            if (cosDelta > 1.0) cosDelta = 1.0;
            if (cosDelta < -1.0) cosDelta = -1.0;
            var deltaAbsDeg = Math.acos(cosDelta) * rad_to_deg;

            // 方向判定 (Cross Product: nX*vY - nY*vX)
            // 正: 低フレット側(Inner), 負: 高フレット側(Outer)
            var crossProd = nX * vY - nY * vX;
            var isLowFretSide = (crossProd > 0) ? 1 : 0;
            var deltaSignedDeg = (isLowFretSide == 1) ? deltaAbsDeg : -deltaAbsDeg;

            // --- 角度ハードリミット (Hard Limits) ---
            var limitAngle = 0.0;
            var relaxAdd = 0.0;

            if (isLowFretSide == 1) {
                limitAngle = 15.0; // Inner limit
                relaxAdd = 5.0;
            } else {
                limitAngle = 30.0; // Outer limit
                relaxAdd = 10.0;
            }
            
            // 小指の緩和 (+5.0)
            if (h == 4) limitAngle += 5.0; 

            // 近距離緩和判定 (ratio < 0.5)
            var ratio = 0.0;
            var isCloseDist = 0;
            if (effLen > 0) {
                ratio = dist / effLen;
                if (ratio < 0.5) {
                    limitAngle += relaxAdd;
                    isCloseDist = 1;
                }
            }

            // 角度ハードリミットチェック
            if (deltaAbsDeg > limitAngle) continue;

            // --- コスト計算: 距離 (Distance Cost) ---
            var distCost = 0.0;
            var distSlope = 10.0;
            if (h == 1) distSlope = 20.0; // Index steep
            if (h == 3) distSlope = 25.0; // Ring steep

            if (ratio < 0.3) {
                distCost = (0.3 - ratio) * 5.0;
            } else if (ratio <= 0.6) {
                distCost = 0.0; // Sweet spot
            } else {
                distCost = (ratio - 0.6) * distSlope;
                if (ratio > 1.0) {
                    // 過伸長ペナルティ (Overstretch x30)
                    distCost += (ratio - 1.0) * 30.0;
                }
            }

            // --- コスト計算: 角度 (Angle Cost) ---
            var comfortAngle = 5.0;
            // 小指も標準の5度
            if (h == 4) comfortAngle = 5.0;

            var angleCost = 0.0;
            var coeffPositive = 1.5; // Inner penalty x1.5
            var coeffNegative = 1.0; // Outer penalty x1.0

            if (deltaSignedDeg > comfortAngle) {
                angleCost = (deltaSignedDeg - comfortAngle) * coeffPositive;
            } else if (deltaSignedDeg < -comfortAngle) {
                angleCost = (Math.abs(deltaSignedDeg) - comfortAngle) * coeffNegative;
            }
            
            // 近距離なら角度コスト半減
            if (isCloseDist == 1) angleCost *= 0.5;

            // --- 総コスト (Difficulty乗算なし) ---
            var currentCost = distCost + angleCost;

            // 最小コストの更新
            if (currentCost < minStCost) {
                minStCost = currentCost;
                bestAngle = ang; // 角度を記録
                foundValidAngle = 1;
            }
        } // end angle loop

        // 結果の格納
        if (foundValidAngle == 1) {
            Stretch_CostTable[p][h][c] = minStCost;
            BestWristAngleTable[p][h][c] = bestAngle; // MC計算用に角度を保存
        }

      } // end combinations
    } // end fingers
  } // end positions
  
  writeln("INFO: Final Stretch Costs & Angles Calculated.");
}
// D. 時間変数と判定フラグの計算
int prevNoteIndex[Notes];
float accumulatedTime[Notes];
float timePenaltyFactor[NotesButFirst];
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
  
  var tp_base = 0.15;   
  var tp_ref = 60.0;
  var tp_exp = 1.5;
  
  for (var j = 1; j <= m; j++) {
     if (accumulatedTime[j] < relaxThreshold) isFast[j] = 1;
     if (accumulatedTime[j] <= legatoThreshold) isLegato[j] = 1;
     
     if (j >= 2) {
         if (note[j] == RestNote) {
             timePenaltyFactor[j] = 0.0;
         } else {
             timePenaltyFactor[j] = tp_base + Math.pow(tp_ref / (accumulatedTime[j] + 0.01), tp_exp);
         }
     }
  }
  writeln("INFO: Time Penalty Factors Pre-calculated.");
}

// ============================================================================
// 3. 変数・目的関数
// ============================================================================

dvar boolean o[Notes][Strings];
dvar boolean y[Notes][HandPosition][Fingers][AllCombinations];
dvar boolean x[Notes][HandPosition];
dvar float wristAngle[Notes] in -90..0;

dexpr float PC[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ?
  0.0 : 
  abs(
    (sum(p in HandPosition) fretPosition[p] * x[i][p]) - 
    (sum(p in HandPosition) fretPosition[p] * x[prevNoteIndex[i]][p])
  );

// SC: String Change (弦移動コスト)
dexpr float SC[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 :
  stringSpacing * abs(
    ( sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) c.corda * y[prevNoteIndex[i]][p][h][c] +
      sum(s in Strings : s in OpenStrings[note[prevNoteIndex[i]]]) s * o[prevNoteIndex[i]][s]) 
      - 
    ( sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) c.corda * y[i][p][h][c] +
      sum(s in Strings : s in OpenStrings[note[i]]) s * o[i][s])
  );


// ST: Geometric Stretch (幾何学的ストレッチ)
dexpr float ST[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(p in HandPosition) sum(h in Fingers) sum(c in Combinations[note[i]])
    Stretch_CostTable[p][h][c] * y[i][p][h][c];

// DH: Physics Action (物理的負荷)
dexpr float DH[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(p in HandPosition) sum(h in Fingers) sum(c in Combinations[note[i]])
    Physics_CostTable[p][h][c] * y[i][p][h][c];

dexpr float CurrentWristAngle[i in Notes] = 
  (note[i] == RestNote) ? 0.0 :
  (
    sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) 
      y[i][p][h][c] * BestWristAngleTable[p][h][c] 
    // + 開放弦なら0度なので加算なし
  );

// ★MCの再定義: 前後の手首角度の変化量 (絶対値)
dexpr float MC[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ?
  0.0 :
  abs(CurrentWristAngle[i] - CurrentWristAngle[prevNoteIndex[i]]);


// --- 総コストの集計 (SLを削除) ---
dexpr float tot_PC = sum(i in NotesButFirst) PC[i] * timePenaltyFactor[i];
dexpr float tot_SC = sum(i in NotesButFirst) SC[i] * timePenaltyFactor[i];
dexpr float tot_ST = sum(i in Notes) ST[i];
dexpr float tot_DH = sum(i in Notes) DH[i];
dexpr float tot_NO = sum(i in Notes) sum(s in Strings : s in OpenStrings[note[i]]) o[i][s];
dexpr float tot_MC = sum(i in NotesButFirst) MC[i] * timePenaltyFactor[i];

minimize
  alpha_PC * d_PC * tot_PC +
  alpha_SC * d_SC * tot_SC +
  alpha_ST * d_ST * tot_ST + 
  alpha_DH * d_DH * tot_DH +
  alpha_NO * d_NO * tot_NO +
  alpha_MC * d_MC * tot_MC;  // SLの項を削除

// ============================================================================
// 4. 制約条件 (Constraints)
// ============================================================================

subject to {
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

  forall(i in NotesButFirst) 
    vinc6_mod:
       if (note[i] != RestNote && prevNoteIndex[i] != i) 
          (PC[i] * timePerMm) <= accumulatedTime[i];


  forall(i in Notes) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
          if (c.fret < p) {
              y[i][p][h][c] == 0;
          }
         if (Stretch_CostTable[p][h][c] >= 50000.0) {
             y[i][p][h][c] == 0;
          }
        }
      }
    }
  }

// -----------------------------------------------------------
  // 1. 物理的制約 (基本)
  // 指の交差、同じ指での不可能な弦移動などを禁止
  // -----------------------------------------------------------
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
             y[i][p][h][c] + 
               sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                   (
                     (h == h_prev && 
                        !((c.corda == c_prev.corda) || 
                          (h != 4 && h != 3  && c.fret == c_prev.fret && abs(c.corda - c_prev.corda) == 1))
                     )
                     ||
                     (c.fret == c_prev.fret && c.corda != c_prev.corda && 
                        ((c.corda < c_prev.corda && h < h_prev) || (c.corda > c_prev.corda && h > h_prev)))
                     ||
                     (c.corda == c_prev.corda && 
                        ((c.fret > c_prev.fret && h < h_prev) || (c.fret < c_prev.fret && h > h_prev)))
                     ||
                     (c.corda != c_prev.corda && c.fret != c_prev.fret &&
                        (
                           // パターン1: 小指側へ行くのに、フレットが2つ以上下がる (例: 人差5F -> 薬3F)
                           (h > h_prev && c.fret < c_prev.fret - 2) 
                           ||
                           // パターン2: 人差し指側へ行くのに、フレットが2つ以上上がる (例: 薬3F -> 人差5F)
                           (h < h_prev && c.fret > c_prev.fret + 2)
                        )
                     )
                   )
               ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
               <= 1;
          }
        }
      }
  }

// -----------------------------------------------------------
  // 2. ★修正: レガート時の制約 (距離制限 + スライド禁止)
  // -----------------------------------------------------------
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isLegato[i] == 1) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
             y[i][p][h][c] + 
               sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                   (
                      // 条件A: 距離が遠すぎる (8フレット超)
                      abs(c.fret - c_prev.fret) > 8 ||  
                      abs(p - p_prev) > 8           ||
                      
                      // 条件B: ★追加 - スライド禁止 (同じ指、同じ弦、異なるフレット)
                      (h == h_prev && c.corda == c_prev.corda && c.fret != c_prev.fret)
                   )
               ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
               <= 1;
          }
        }
      }
  }

  // -----------------------------------------------------------
  // 3. ★追加: 速弾き時の距離制約
  // 速弾き(isFast)なら、12フレット(または12ポジション)以上の大跳躍を禁止
  // -----------------------------------------------------------
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
             y[i][p][h][c] + 
               sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                   (
                      abs(c.fret - c_prev.fret) > 12 ||  // フレット距離が12超
                      abs(p - p_prev) > 12               // ハンド位置距離が12超
                   )
               ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
               <= 1;
          }
        }
      }
  }

  // -----------------------------------------------------------
  // 4. 速弾き・レガート時の特殊遷移制約 (既存)
  // 特定の弦移動パターンなどを禁止
  // -----------------------------------------------------------
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
          y[i][p][h][c] + 
             sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                 (
                   (c.fret > c_prev.fret && h < h_prev && c.corda != c_prev.corda) ||
                   (c.fret < c_prev.fret && h > h_prev && c.corda != c_prev.corda)
                   ||
                   (isLegato[i] == 1 && !(c.corda == c_prev.corda || p == p_prev))
                 )
             ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev]
             <= 1;
        }
      }
    }
  }
}

// ============================================================================
// 5. 出力設定
// ============================================================================
main {
  cplex.epgap = 0.01;
  thisOplModel.generate();
  if (cplex.solve()) {
    var obj = cplex.getObjValue();
    var bestObj = cplex.getBestObjValue();
    var gap = Math.abs(obj - bestObj) / (1e-10 + Math.abs(obj));
    
    writeln(">>> 解が見つかりました。");
    writeln("    Objective (Total Cost): ", obj);
    writeln("    Best Bound            : ", bestObj);
    writeln("    Relative Gap          : ", gap * 100, "%");
    thisOplModel.postProcess();
  } else {
    writeln(">>> 解が見つかりませんでした（または時間切れで解なし）。");
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
  var costPC = alpha_PC * d_PC * tot_PC;
  var costSC = alpha_SC * d_SC * tot_SC;
  var costST = alpha_ST * d_ST * tot_ST;
  var costDH = alpha_DH * d_DH * tot_DH;
  var costNO = alpha_NO * d_NO * tot_NO;
  var costMC = alpha_MC * d_MC * tot_MC;
  // var costSL = ... (削除)

  writeln("  Position Change (PC): ", costPC);
  writeln("  Finger Move     (MC): ", costMC);
  writeln("  String Change   (SC): ", costSC);
  writeln("  Geo Stretch     (ST): ", costST);
  writeln("  Phys Action     (DH): ", costDH);
  writeln("  Open String     (NO): ", costNO);
  // writeln("  Slide Distance  (SL): ", costSL); (削除)
  writeln("-----------------------------------------");
  writeln("  Total Cost (Sum)    : ", costPC + costSC + costST + costDH + costNO + costMC);
  writeln("-----------------------------------------");
}