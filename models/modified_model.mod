/*********************************************
 * OPL Model for Guitar Tablature Generation
 * Modified: Map integer neck_thickness to reduction rate
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

// 変更: 整数で受け取る (1, 2, or 3)
int neck_thickness = ...; 

float timePerMm = ...;
float fingerLengths_mm[Fingers] = ...;
float fingerDifficulty[Fingers] = ...;
float natural_min_spread_mm[FingersButFirst] = ...;
float stringAction12thMm = ...;

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
// B & C. ストレッチ(Stretch) と 物理負荷(Physics) の計算
// (Updated: Map neck_thickness 1/2/3 to Reduction Rates)
// ============================================================================
execute {
  var PI = 3.141592653589793;

  // --- 1. ローカルパラメータ設定 ---
  
  var knuckleDist = new Array();
  knuckleDist[1] = 0.0;  
  for (var f in FingersButFirst) {
     knuckleDist[f] = natural_min_spread_mm[f];
  }

  // Limit Ratios (最大伸長倍率)
  var limitRatios = new Array();
  limitRatios[1] = 1.3; limitRatios[2] = 1.05; limitRatios[3] = 1.05; limitRatios[4] = 1.1; 
  
  // Base Factors (有効指長係数)
  var baseFactors = new Array();
  baseFactors[1] = 0.7; baseFactors[2] = 0.9; baseFactors[3] = 0.85; baseFactors[4] = 0.95;
  // String Tension (Physics用)
  var stringTension = new Array();
  stringTension[1] = 1.0; stringTension[2] = 1.0; stringTension[3] = 1.0;
  stringTension[4] = 1.2; stringTension[5] = 1.4; stringTension[6] = 1.6;

  // --- Neck Factor Parameters Mapping ---
  var max_reduction_at_p16 = 0.30; // Default fallback

  // 整数モード(1, 2, 3)から減少率(0.15, 0.225, 0.30)へ変換
  if (neck_thickness == 1) {
      max_reduction_at_p16 = 0.15;
  } else if (neck_thickness == 2) {
      max_reduction_at_p16 = 0.225;
  } else if (neck_thickness == 3) {
      max_reduction_at_p16 = 0.30;
  }
  
  writeln("INFO: Neck Thickness Mode = ", neck_thickness, " -> Max Reduction = ", max_reduction_at_p16);

  var target_reduction_at_p12 = 0.03; 
  var p_max_ref = 16.0;

  // 指数kの計算: k = ln(0.03 / Max) / ln(12 / 16)
  var curve_exponent = 1.0;
  if (max_reduction_at_p16 > target_reduction_at_p12) {
      curve_exponent = Math.log(target_reduction_at_p12 / max_reduction_at_p16) / Math.log(12.0 / 16.0);
  }
  writeln("INFO: Neck Factor Curve Exponent k = ", curve_exponent);

  // 指ごとの倍率 (Index/Middle=0.0, Ring=1.2, Pinky=1.3)
  var finger_mult = new Array();
  finger_mult[1] = 0.0;
  finger_mult[2] = 0.0;
  finger_mult[3] = 1.2;
  finger_mult[4] = 1.3;

  writeln("INFO: Calculating v17 Stretch Costs...");

  for(var p in HandPosition) {
    // 基準点(Pivot)は人差し指付け根、1弦(Y=0)固定
    var pivotX = fretPosition[p];
    var pivotY = 0.0; 

    for(var h in Fingers) { 
      for(var c in AllCombinations) {
        
        // 初期化
        Stretch_CostTable[p][h][c] = 100000.0;
        Physics_CostTable[p][h][c] = 0.0;
        BestWristAngleTable[p][h][c] = 0.0;

        // 論理的制約
        if (c.fret < p) continue; 

// -------------------------------------------------------
        // 1. 物理的負荷 (Physics Cost)
        // -------------------------------------------------------
        var targetString = c.corda;
        
        // E_GPa
        var E_GPa = new Array();
        E_GPa[1] = 179.0; E_GPa[2] = 188.0; E_GPa[3] = 177.0;
        E_GPa[4] = 62.0;  E_GPa[5] = 42.0;  E_GPa[6] = 33.0;

        // Area_m2
        var Area_m2 = new Array();
        Area_m2[1] = 5.13e-8; Area_m2[2] = 8.56e-8; Area_m2[3] = 1.48e-7;
        Area_m2[4] = 3.55e-7; Area_m2[5] = 6.79e-7; Area_m2[6] = 1.10e-6;

        // Tension_N
        var Tension_N = new Array();
        Tension_N[1] = 73.0; Tension_N[2] = 70.0; Tension_N[3] = 68.0;
        Tension_N[4] = 75.0; Tension_N[5] = 78.0; Tension_N[6] = 76.0;

        // 幾何パラメータ (mm)
        var a_mm = 0.5 + ((stringAction12thMm - 0.5) * c.fret / 12.0);
        var l_mm = scaleLength - fretPosition[c.fret];

        var forceIndex = 0.0;
        if (l_mm > 0.001) {
            var l_m = l_mm / 1000.0;
            var a_m = a_mm / 1000.0;
            var E = E_GPa[targetString] * 1.0e9;
            var A = Area_m2[targetString];
            var T = Tension_N[targetString];

            var hyp_m = Math.sqrt(l_m * l_m + a_m * a_m);
            var sin_theta = a_m / hyp_m;
            var cos_theta = l_m / hyp_m;
            var strain_term = (1.0 / cos_theta) - 1.0;
            var F_newton = (T + (E * A * strain_term)) * sin_theta;
            forceIndex = F_newton;
        }

        var scalingFactor = 7.5; 
        var diff = fingerDifficulty[h];
        Physics_CostTable[p][h][c] = (forceIndex * scalingFactor) * diff;

        // -------------------------------------------------------
        // 2. 幾何学的ストレッチ (Stretch Cost)
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

            // --- Neck Factor Calculation ---
            // ポジション基準 (pは現在のハンドポジション番号)
            var current_pos = p; 
            var ratio = 0.0;
            
            if (current_pos >= 0) {
                ratio = current_pos / p_max_ref;
            }
            if (ratio > 1.0) ratio = 1.0;

            // 減少率 = Max * (ratio ^ k) * finger_mult
            var reduction = max_reduction_at_p16 * Math.pow(ratio, curve_exponent) * finger_mult[h];
            
            // 係数 (1.0 - 減少分), 最低0.1
            var neckFactor = 1.0 - reduction;
            if (neckFactor < 0.1) neckFactor = 0.1;

            // 有効指長 (Effective Length)
            var effLen = fingerLengths_mm[h] * baseFactors[h] * neckFactor;

            // 距離のハードリミット判定
            if (effLen > 0 && dist > effLen * limitRatios[h]) continue;

            // --- 角度計算 ---
            var nX = -Math.sin(thetaRad);
            var nY = Math.cos(thetaRad);
            
            var dotProd = vX * nX + vY * nY;
            var cosDelta = (dist > 0.001) ? (dotProd / dist) : 1.0;
            if (cosDelta > 1.0) cosDelta = 1.0;
            if (cosDelta < -1.0) cosDelta = -1.0;
            var deltaAbsDeg = Math.acos(cosDelta) * rad_to_deg;

            var crossProd = nX * vY - nY * vX;
            var isLowFretSide = (crossProd > 0) ? 1 : 0;
            var deltaSignedDeg = (isLowFretSide == 1) ? deltaAbsDeg : -deltaAbsDeg;

            // --- 角度ハードリミット ---
            var limitAngle = 0.0;
            var relaxAdd = 0.0;

            if (isLowFretSide == 1) {
                limitAngle = 15.0; // Inner limit
                relaxAdd = 5.0;
            } else {
                limitAngle = 30.0; // Outer limit
                relaxAdd = 10.0;
            }
            
            // 小指の緩和
            if (h == 4) limitAngle += 5.0; 
            
            // 近距離緩和
            var dist_ratio = 0.0;
            var isCloseDist = 0;
            if (effLen > 0) {
                dist_ratio = dist / effLen;
                if (dist_ratio < 0.5) {
                    limitAngle += relaxAdd;
                    isCloseDist = 1;
                }
            }

            // 角度ハードリミットチェック
            if (deltaAbsDeg > limitAngle) continue;

            // --- コスト計算 ---
            var distCost = 0.0;
            var distSlope = 20.0;

            if (dist_ratio < 0.3) {
                distCost = (0.3 - dist_ratio) * 5.0;
            } else if (dist_ratio <= 0.6) {
                distCost = 0.0;
            } else {
                distCost = (dist_ratio - 0.6) * distSlope;
                if (dist_ratio > 1.0) {
                    distCost += (dist_ratio - 1.0) * 30.0;
                }
            }

            // --- コスト計算: 角度 (Angle Cost) ---
            var comfortAngle = 5.0;
            var angleCost = 0.0;
            var coeffPositive = 1.5; 
            var coeffNegative = 1.0;

            if (deltaSignedDeg > comfortAngle) {
                angleCost = (deltaSignedDeg - comfortAngle) * coeffPositive;
            } else if (deltaSignedDeg < -comfortAngle) {
                angleCost = (Math.abs(deltaSignedDeg) - comfortAngle) * coeffNegative;
            }
            
            if (isCloseDist == 1) angleCost *= 0.5;

            var currentCost = distCost + angleCost;

            if (currentCost < minStCost) {
                minStCost = currentCost;
                bestAngle = ang;
                foundValidAngle = 1;
            }
        } // end angle loop

        if (foundValidAngle == 1) {
            Stretch_CostTable[p][h][c] = minStCost;
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
  
  var relaxThreshold = 250; 
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


// --- 総コストの集計  ---
dexpr float tot_PC = sum(i in NotesButFirst) PC[i] * timePenaltyFactor[i];
dexpr float tot_SC = sum(i in NotesButFirst) SC[i] * timePenaltyFactor[i];
dexpr float tot_ST = sum(i in Notes) ST[i];
dexpr float tot_DH = sum(i in Notes) DH[i];
dexpr float tot_NO = sum(i in Notes) sum(s in Strings : s in OpenStrings[note[i]]) o[i][s];
minimize
  alpha_PC * d_PC * tot_PC +
  alpha_SC * d_SC * tot_SC +
  alpha_ST * d_ST * tot_ST + 
  alpha_DH * d_DH * tot_DH +
  alpha_NO * d_NO * tot_NO;

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


forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
           y[i][p][h][c] + 
           sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
               (h == h_prev && 
                 !(
                   // 許可条件A: 同じ弦であること（通常の移動）
                   (c.corda == c_prev.corda) 
                   || 
                   // 許可条件B: ジョイント（人差指のみ、同じフレット、隣接弦）
                   (c.fret == c_prev.fret && abs(c.corda - c_prev.corda) == 1)
                 )
               )
           ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
           <= 1;
        }
      }
    }
  }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  // ポジション移動を伴わないスライドの禁止
  // (同一ポジション p かつ 同一指 h で、同じ弦・異なるフレットへの移動を禁止)
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
           // 現在のノートが ポジションp / 指h / 組み合わせc で弾かれる場合...
           y[i][p][h][c] + 
           // 直前のノートが 「同じポジション p」「同じ指 h」「同じ弦」「異なるフレット(移動あり)」
           // であった場合、その組み合わせの和は1以下でなければならない（＝両立しない）
           sum(c_prev in Combinations[note[prevNoteIndex[i]]] : 
               (c.corda == c_prev.corda && c.fret != c_prev.fret)
           ) y[prevNoteIndex[i]][p][h][c_prev] 
           <= 1;
        }
      }
    }
  }


// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  // ② 速弾き (isFast = 1) 時の制約 (relaxThreshold < 200ms)
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
           y[i][p][h][c] + 
           sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
               (
                 // パターンA: フレットは上がった(>)のに、指番号は下がった(<) → 禁止
                 (c.fret > c_prev.fret && h < h_prev) 
                 ||
                 // パターンB: フレットは下がった(<)のに、指番号は上がった(>) → 禁止
                 (c.fret < c_prev.fret && h > h_prev)
                 ||
                 // パターンC: 同フレットで弦番号が減った(高音弦へ)のに、指番号も減った(<) → 禁止
                 (c.fret == c_prev.fret && c.corda < c_prev.corda && h < h_prev)
                 ||
                 // パターンD: 同フレットで弦番号が増えた(低音弦へ)のに、指番号も増えた(>) → 禁止
                 (c.fret == c_prev.fret && c.corda > c_prev.corda && h > h_prev)
               )
           ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
           <= 1;
        }
      }
    }
  }


  // 2-2. [技術制限] 同音連打時の指変更禁止 (トリル対策)
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
             y[i][p][h][c] + 
             sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                 (c.corda == c_prev.corda && c.fret == c_prev.fret && h != h_prev)
             ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
             <= 1;
          }
        }
      }
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  // ③ レガート (isLegato = 1) 時の制約 (legatoThreshold <= 50ms)
  // ※ isLegato=1 の時は自動的に isFast=1 の制約も適用されます
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::


  // 3-1. [技術制限] スライドの禁止
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isLegato[i] == 1) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
             y[i][p][h][c] + 
             sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                 (h == h_prev && c.corda == c_prev.corda && c.fret != c_prev.fret)
             ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
             <= 1;
          }
        }
      }
  }

  // 3-2. [安定性制限] アンカーの維持
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isLegato[i] == 1) {
    forall(p in HandPosition) {
      forall(h in Fingers) {
        forall(c in Combinations[note[i]]) {
          y[i][p][h][c] + 
             sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                 (c.corda != c_prev.corda && p != p_prev)
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
  //cplex.epgap = 0.03;
  cplex.tilim = 10000; // 必要に応じてタイムリミットを設定

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

  writeln("  Position Change (PC): ", costPC);
  writeln("  String Change   (SC): ", costSC);
  writeln("  Geo Stretch     (ST): ", costST);
  writeln("  Phys Action     (DH): ", costDH);
  writeln("  Open String     (NO): ", costNO);
  writeln("-----------------------------------------");
  writeln("  Total Cost (Sum)    : ", costPC + costSC + costST + costDH + costNO);
  writeln("-----------------------------------------");
}