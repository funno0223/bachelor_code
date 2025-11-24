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

float rad_to_deg = 180.0 / 3.141592653589793;
float deg_to_rad = 3.141592653589793 / 180.0;

// コスト係数
float d_PC = ...;
float d_SC = ...;
float d_ST = ...;
float d_SL = ...;
float d_DH = ...;
float d_NO = ...;
float d_MC = ...;

float alpha_PC = ...;
float alpha_SC = ...;
float alpha_ST = ...;
float alpha_SL = ...;
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

// B & C ストレッチ(Stretch) と 物理負荷(Physics) の独立計算
execute {
  var PI = 3.141592653589793;
  var knuckleDist = new Array();
  knuckleDist[1] = 0.0;
  for(var f=2; f<=4; f++) {
     knuckleDist[f] = natural_min_spread_mm[f];
  }
  
  var limitRatios = new Array();
  limitRatios[1] = 1.0; limitRatios[2] = 1.05; limitRatios[3] = 1.05;
  limitRatios[4] = 1.2; 
  
  // 有効指長係数
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
        
        Stretch_CostTable[p][h][c] = 0.0;
        Physics_CostTable[p][h][c] = 0.0;

        // 0. 論理的制約
        if (c.fret < p) {
             Stretch_CostTable[p][h][c] = 100000.0;
             continue; 
        }

        // --- Stretch Calculation ---
        var targetString = c.corda;
        var maxRotation = 40.0;
        var baseTheta = maxRotation * (targetString - 6.0) / 5.0;
        var fretRotationMax = (c.fret / 17.0) * 15.0;
        var stringFactor = (targetString - 1.0) / 5.0;
        var fretRotation = fretRotationMax * stringFactor;
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

        var neckFactor = 1.0;
        if (c.fret >= 15) {
            var ratioHigh = (c.fret - 15.0) / (f_max - 15.0);
            if (ratioHigh > 1.0) ratioHigh = 1.0;
            neckFactor = 1.0 - (0.15 * ratioHigh);
        }
        var effLen = fingerLengths_mm[h] * baseFactors[h] * neckFactor;
        if (effLen > 0 && dist > effLen * limitRatios[h]) {
             Stretch_CostTable[p][h][c] = 100000.0;
             continue;
        }

        var distCost = 0.0;
        var ratio = 0.0;
        var distSlope = 10.0;
        if (h == 3) distSlope = 25.0;

        if (effLen > 0) {
            ratio = dist / effLen;
            if (ratio < 0.3) {
                distCost = (0.3 - ratio) * 5.0;
            } else if (ratio <= 0.6) {
                distCost = 0.0;
            } else {
                distCost = (ratio - 0.6) * distSlope;
                if (ratio > 1.0) distCost += (ratio - 1.0) * 20.0;
            }
        }

        var angleCost = 0.0;
        var dotProd = vX * nX + vY * nY;
        var cosDelta = (dist > 0.001) ? (dotProd / dist) : 1.0;
        if (cosDelta > 1.0) cosDelta = 1.0;
        if (cosDelta < -1.0) cosDelta = -1.0;
        var deltaDeg = Math.acos(cosDelta) * rad_to_deg;

        var baseMaxAngle = 15.0;
        if (h == 4) baseMaxAngle = 20.0;
        var maxAngle = baseMaxAngle;
        if (c.fret >= 12) maxAngle = Math.max(10.0, baseMaxAngle - (c.fret - 12) * 0.5);
        var angleMultiplier = 0.5; 
        if (effLen > 0 && ratio >= 0.3 && ratio <= 0.6) angleMultiplier = 0.2;
        
        if (deltaDeg > maxAngle) {
            angleCost = (deltaDeg - maxAngle) * angleMultiplier;
        }

        var diff = fingerDifficulty[h];
        Stretch_CostTable[p][h][c] = (distCost + angleCost) * diff;

        // --- Physics Calculation ---
        var a_mm = 0.5 + (2.0 * c.fret / 12.0);
        var l_mm = scaleLength - fretPosition[c.fret];
        var tau = stringTension[targetString];
        var forceIndex = 0.0;
        if (l_mm > 0.001) {
             forceIndex = (2.0 * tau * a_mm) / (l_mm * tanTheta);
        }
        Physics_CostTable[p][h][c] = (forceIndex * 100.0) * diff;
      }
    }
  }
  writeln("INFO: Separated Cost Tables Generated.");
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

// 現在のハンドポジションの絶対位置 (mm)
dexpr float AbsHandPos[i in Notes] = 
  (note[i] == RestNote) ? 0.0 :
    sum(p in HandPosition) fretPosition[p] * x[i][p];

// 現在の発音位置の絶対位置 (mm) ※開放弦は0フレット位置
dexpr float AbsNotePos[i in Notes] = 
  (note[i] == RestNote) ? 0.0 :
    (
      sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) fretPosition[c.fret] * y[i][p][h][c] +
      sum(s in Strings : s in OpenStrings[note[i]]) fretPosition[0] * o[i][s]
    );

// ----------------------------------------------------------------------------

// PC: Position Change (ハンドポジションの移動距離)
dexpr float PC[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 : 
  abs(AbsHandPos[prevNoteIndex[i]] - AbsHandPos[i]);

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

dexpr float SL[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 :
  sum(h in Fingers)
    sum(p in HandPosition, c in Combinations[note[i]])
      sum(p_prev in HandPosition, c_prev in Combinations[note[prevNoteIndex[i]]] : c.corda == c_prev.corda) 
        (
          y[i][p][h][c] * y[prevNoteIndex[i]][p_prev][h][c_prev] 
          * abs(c.fret - c_prev.fret)
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

// MC: Movement Cost (指の相対移動)機能
// 計算式: |(現在の指相対位置) - (直前の指相対位置)|
// ここで、指相対位置 = (発音位置 - ハンド位置)
dexpr float MC[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 :
  abs(
      (AbsNotePos[i] - AbsHandPos[i]) - 
      (AbsNotePos[prevNoteIndex[i]] - AbsHandPos[prevNoteIndex[i]])
  );

// --- 総コストの集計 ---
dexpr float tot_PC = sum(i in NotesButFirst) PC[i] * timePenaltyFactor[i];
dexpr float tot_SC = sum(i in NotesButFirst) SC[i] * timePenaltyFactor[i];
dexpr float tot_SL = sum(i in NotesButFirst) SL[i] * timePenaltyFactor[i];
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
  alpha_MC * d_MC * tot_MC +
  alpha_SL * d_SL * tot_SL;

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

  // 遷移制約
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
      forall(p in HandPosition) {
        forall(h in Fingers) {
          forall(c in Combinations[note[i]]) {
             y[i][p][h][c] + 
               sum(p_prev in HandPosition, h_prev in Fingers, c_prev in Combinations[note[prevNoteIndex[i]]] : 
                   (
                     // --- 1. 既存の物理的制約 (指の交差や不自然な動きの禁止) ---
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
                     )
                     
                     // --- 2. ★追加: レガート時の距離フィルタリング (高速化の鍵) ---
                     // 「レガート指定」かつ「距離が遠すぎる」場合も、この禁止リスト(sum)に加える
                     ||
                     (
                        isLegato[i] == 1 && 
                        (
                          abs(c.fret - c_prev.fret) > 8  ||  // フレット位置が8以上離れている
                          abs(p - p_prev) > 8                // またはハンドポジションが8以上離れている
                        )
                     )
                   )
               ) y[prevNoteIndex[i]][p_prev][h_prev][c_prev] 
               <= 1;
          }
        }
      }
  }

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
  cplex.tilim = 600;

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
  var costMC = alpha_MC * d_MC * tot_MC; // ★追加
  var costSL = alpha_SL * d_SL * tot_SL;

  writeln("  Position Change (PC): ", costPC);
  writeln("  Finger Move     (MC): ", costMC); // ★追加
  writeln("  String Change   (SC): ", costSC);
  writeln("  Geo Stretch     (ST): ", costST);
  writeln("  Phys Action     (DH): ", costDH);
  writeln("  Open String     (NO): ", costNO);
  writeln("  Slide Distance  (SL): ", costSL);
  writeln("-----------------------------------------");
  writeln("  Total Cost (Sum)    : ", costPC + costSC + costST + costDH + costNO + costMC + costSL);
  writeln("-----------------------------------------");
}