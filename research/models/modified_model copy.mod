/*********************************************
 * OPL Model for Guitar Tablature Generation
 * Approach: Feasible Range ST (Discretized 5-deg)
 * Optimization: Sparse Modeling (Tuple Set)
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

// --- [変更] スパース化（解空間圧縮）用タプル定義 ---
tuple PHC {
  int p;
  int h;
  combination c;
}

string MidiNames[0..127] = ...;

int m = ...;
range Notes = 1..m;
range NotesButFirst = 2..m;
int note[Notes] = ...;
float availableTime[Notes] = ...;

// [変更] 各ノートごとに有効な(p, h, c)の組み合わせを保持する集合
{PHC} ValidPHCs[Notes];

range Fingers = 1..4;
range FingersButFirst = 2..4;
range HandPosition = 1..p_max;

// --- 物理パラメータ群 ---

float scaleLength = ...;
float fretPosition[Frets];
float stringSpacing = ...;
int neck_thickness = ...; // 1, 2, or 3

float timePerMm = ...;
float fingerLengths_mm[Fingers] = ...;
float fingerDifficulty[Fingers] = ...;
float natural_min_spread_mm[FingersButFirst] = ...;
float stringAction12thMm = ...;

// --- 離散化パラメータ (Discretization) ---
int AngleStep = 5;       // 5度刻み
int MaxAngleIdx = 18;    // 0度(0) ～ -90度(18)
range AngleIndices = 0..MaxAngleIdx;

// --- テーブル定義 ---
// 最適コスト (固定値)
float Stretch_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];

// 物理的な許容範囲 (整数インデックス 0..18)
int MinAngleIdxTable[p in HandPosition][h in Fingers][c in AllCombinations];
int MaxAngleIdxTable[p in HandPosition][h in Fingers][c in AllCombinations];

// 物理的な許容範囲 (最適値 + Margin_ST 以内の範囲)
float MinAngleTable[p in HandPosition][h in Fingers][c in AllCombinations];
float MaxAngleTable[p in HandPosition][h in Fingers][c in AllCombinations];

float Physics_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];

float rad_to_deg = 180.0 / 3.141592653589793;
float deg_to_rad = 3.141592653589793 / 180.0;

// コスト係数
float d_PC = ...;
float d_AT = ...;
float d_ST = ...;
float d_DH = ...;
float d_NO = ...;

float alpha_PC = ...;
float alpha_AT = ...;
float alpha_ST = ...;
float alpha_DH = ...;
float alpha_NO = ...;

// 前処理用パラメータ: STコストの許容閾値
float Margin_ST = 3.0;

// ============================================================================
// 2. 前処理 (Execute Blocks)
// ============================================================================

// A. フレット位置計算
execute {
  for (var f in Frets) {
    fretPosition[f] = scaleLength - (scaleLength / Math.pow(2, f / 12.0));
  }
}

// B. STコスト & 許容範囲(離散)の計算 & [変更] 有効集合の生成
execute {
  var PI = 3.141592653589793;

  // ナックル位置
  var knuckleDist = new Array();
  knuckleDist[1] = 0.0;  
  for (var f in FingersButFirst) knuckleDist[f] = natural_min_spread_mm[f];

  // 基準最大リーチ
  var ReachCoeffs = new Array();
  ReachCoeffs[1] = 1.0; ReachCoeffs[2] = 0.95; ReachCoeffs[3] = 0.90; ReachCoeffs[4] = 1.0;

  // Neck Reduction (Thickness 1-3 mapping)
  var max_reduction_at_p16 = 0.20;
  if (neck_thickness == 1) max_reduction_at_p16 = 0.15;
  else if (neck_thickness == 2) max_reduction_at_p16 = 0.20;
  else if (neck_thickness == 3) max_reduction_at_p16 = 0.25;

  var target_reduction_at_p12 = 0.03; 
  var p_max_ref = 16.0;
  var curve_exponent = 1.0;
  if (max_reduction_at_p16 > target_reduction_at_p12) {
      curve_exponent = Math.log(target_reduction_at_p12 / max_reduction_at_p16) / Math.log(12.0 / 16.0);
  }

  // Finger Multipliers
  var finger_mult = new Array();
  finger_mult[1] = 0.3; finger_mult[2] = 0.3; finger_mult[3] = 0.8; finger_mult[4] = 0.9;

  // Angle Limits Function
  function getLowLimit(fingerIdx) {
      if (fingerIdx == 1) return 15.0; 
      if (fingerIdx == 2) return 15.0; 
      if (fingerIdx == 3) return 20.0; 
      if (fingerIdx == 4) return 25.0; 
      return 15.0;
  }
  var high_limit_base = 30.0;

  // Cost Constants
  var weight_dist = 1.0;
  var weight_angle = 1.0;
  var eps = 0.01;

  writeln("INFO: Calculating ST Costs & Feasible Ranges (Threshold Margin: " + Margin_ST + ")...");

  for(var p in HandPosition) {
    var pivotX = fretPosition[p];
    var pivotY = 0.0; 

    for(var h in Fingers) { 
      var currentBaseReach = fingerLengths_mm[h] * ReachCoeffs[h];

      for(var c in AllCombinations) {
        
        Stretch_CostTable[p][h][c] = 100000.0;
        MinAngleIdxTable[p][h][c] = 0;
        MaxAngleIdxTable[p][h][c] = -1; // Invalid state
        Physics_CostTable[p][h][c] = 0.0;

        if (c.fret < p) continue; 

        // Physics Cost
        var targetString = c.corda;
        var E_GPa = new Array(); E_GPa[1]=179.0; E_GPa[2]=188.0; E_GPa[3]=177.0; E_GPa[4]=62.0; E_GPa[5]=42.0; E_GPa[6]=33.0;
        var Area_m2 = new Array(); Area_m2[1]=5.13e-8; Area_m2[2]=8.56e-8; Area_m2[3]=1.48e-7; Area_m2[4]=3.55e-7;
        Area_m2[5]=6.79e-7; Area_m2[6]=1.10e-6;
        var Tension_N = new Array(); Tension_N[1]=73.0; Tension_N[2]=70.0; Tension_N[3]=68.0; Tension_N[4]=75.0; Tension_N[5]=78.0; Tension_N[6]=76.0;
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

        // --- Geometric Stretch Loop ---
        var minStCost = 100000.0;
        var costs = new Array();
        for(var i=0; i<=90; i++) costs[i] = -1.0; 

        for (var ang = -90; ang <= 0; ang++) {
            var thetaRad = ang * deg_to_rad;
            var d = knuckleDist[h];
            var kX = pivotX + (d * Math.cos(thetaRad));
            var kY = pivotY + (d * Math.sin(thetaRad));
            var tX = fretPosition[c.fret];
            var tY = (c.corda - 1) * stringSpacing;
            var dist = Math.sqrt(Math.pow(tX - kX, 2) + Math.pow(tY - kY, 2));

            var ratio = 0.0;
            if (p >= 0) ratio = p / p_max_ref;
            if (ratio > 1.0) ratio = 1.0;
            var reduction = max_reduction_at_p16 * Math.pow(ratio, curve_exponent) * finger_mult[h];
            var neckFactor = Math.max(0.1, 1.0 - reduction);
            var maxReach = currentBaseReach * neckFactor;
            
            var u_dist = 999.0;
            if (maxReach > 0.001) u_dist = dist / maxReach;
            if (u_dist > 1.0) continue; 
            
            // Angle Check
            var nX = -Math.sin(thetaRad);
            var nY = Math.cos(thetaRad);
            var dotProd = (tX - kX) * nX + (tY - kY) * nY;
            var cosDelta = (dist > 0.001) ? (dotProd / dist) : 1.0;
            cosDelta = Math.max(-1.0, Math.min(1.0, cosDelta));
            var deltaAbsDeg = Math.acos(cosDelta) * rad_to_deg;

            var crossProd = nX * (tY - kY) - nY * (tX - kX);
            var isLowFretSide = (crossProd > 0) ? 1 : 0;
            var limit_base = high_limit_base;
            if (isLowFretSide == 1) limit_base = getLowLimit(h);

            // Relaxation
            var relax_angle = 0.0;
            if (u_dist < 0.5) {
                if (isLowFretSide == 1) relax_angle = 10.0; 
                else relax_angle = 5.0; 
            }
            var final_limit = limit_base + relax_angle;

            var u_angle = 999.0;
            if (final_limit > 0.0) u_angle = deltaAbsDeg / final_limit;
            if (u_angle > 1.0) continue; 

            // Cost Calculation
            var eps = 0.01;
            var weight_dist = 1.0;
            var weight_angle = 1.0;
            var c_dist = weight_dist * u_dist / (1.0 - u_dist + eps);
            var dir_coeff = (isLowFretSide == 1) ? 1.5 : 1.0;
            var c_angle = (weight_angle * dir_coeff) * u_angle / (1.0 - u_angle + eps);

            var currentCost = c_dist + c_angle;

            // Store (Index shifted by +90)
            costs[ang + 90] = currentCost;

            if (currentCost < minStCost) {
                minStCost = currentCost;
            }
        } 

        // --- Store Result & Discretize ---
        if (minStCost < 50000.0) {
           Stretch_CostTable[p][h][c] = minStCost;
            
            // 1. Determine Continuous Range
            var threshold = minStCost + Margin_ST;
            var valid_min_deg = 10.0;   // closer to 0
            var valid_max_deg = -100.0; // closer to -90
            
            for(var a=-90; a<=0; a++) {
                var cVal = costs[a+90];
                if (cVal >= 0 && cVal <= threshold) {
                    if (valid_min_deg > a) valid_min_deg = a;
                    if (valid_max_deg < a) valid_max_deg = a;
                }
            }
            
            // 2. Map to 5-degree grid indices
            // Angle = -1 * k * AngleStep (k=0..18)
            var valid_k_min = 999;
            var valid_k_max = -999;
            
            for (var k = 0; k <= MaxAngleIdx; k++) {
                 var gridAng = -1.0 * k * AngleStep; 
                 // Allow slight float error margin
                 if (gridAng <= valid_min_deg + 0.01 && gridAng >= valid_max_deg - 0.01) {
                     if (valid_k_min > k) valid_k_min = k; // closest to 0
                     if (valid_k_max < k) valid_k_max = k; // closest to -90
                   }
               }

            if (valid_k_min <= valid_k_max) {
                 MinAngleIdxTable[p][h][c] = valid_k_min;
                 MaxAngleIdxTable[p][h][c] = valid_k_max;
            } else {
                 // Fallback: range exists but missed the 5-deg grid
                 // Snap to nearest grid point
                 var center = (valid_min_deg + valid_max_deg) / 2.0;
                 var nearest_k = Math.round(Math.abs(center) / AngleStep);
                 if (nearest_k > MaxAngleIdx) nearest_k = MaxAngleIdx;
                 
                 MinAngleIdxTable[p][h][c] = nearest_k;
                 MaxAngleIdxTable[p][h][c] = nearest_k;
                 
                 // Penalty for snapping
                 Stretch_CostTable[p][h][c] += 0.5; 
            }
            
        } else {
             MinAngleIdxTable[p][h][c] = 0;
             MaxAngleIdxTable[p][h][c] = -1; // Invalid
        }
      } 
    } 
  }

  // [変更] 50000未満の有効な組み合わせのみを集合に登録する
  writeln("INFO: Generating Sparse Sets for optimization...");
  for (var i in Notes) {
    if (note[i] != RestNote) {
       for(var p in HandPosition) {
         for(var h in Fingers) {
           for(var c in Combinations[note[i]]) {
             // コスト計算済みのテーブルを参照し、閾値未満なら採用
             if (Stretch_CostTable[p][h][c] < 50000.0) {
                ValidPHCs[i].add(p, h, c);
             }
           }
         }
       }
    }
  }
}

// C. 時間計算
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
}

// ============================================================================
// 3. 変数・目的関数
// ============================================================================

dvar boolean o[Notes][Strings];
dvar boolean x[Notes][HandPosition];

// [変更] 連続変数ではなく、0..18の整数インデックス
dvar int angleIndex[Notes] in AngleIndices;

// [変更] 有効な集合(ValidPHCs)の上でのみ定義される疎な変数
dvar boolean y[i in Notes][ValidPHCs[i]];

dexpr float PC[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 : 
  abs(
    (sum(p in HandPosition) fretPosition[p] * x[i][p]) - 
    (sum(p in HandPosition) fretPosition[p] * x[prevNoteIndex[i]][p])
  );

// ATコスト: インデックス差分 × ステップ(5度)
dexpr float AT[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 : 
  AngleStep * abs(angleIndex[i] - angleIndex[prevNoteIndex[i]]);

// [変更] STコスト: タプルセットを反復
dexpr float ST[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(item in ValidPHCs[i]) 
    Stretch_CostTable[item.p][item.h][item.c] * y[i][item];

// [変更] DHコスト: タプルセットを反復
dexpr float DH[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(item in ValidPHCs[i]) 
    Physics_CostTable[item.p][item.h][item.c] * y[i][item];

dexpr float tot_PC = sum(i in NotesButFirst) PC[i] * timePenaltyFactor[i];
dexpr float tot_AT = sum(i in NotesButFirst) AT[i] * timePenaltyFactor[i];
dexpr float tot_ST = sum(i in Notes) ST[i];
dexpr float tot_DH = sum(i in Notes) DH[i];
dexpr float tot_NO = sum(i in Notes) sum(s in Strings : s in OpenStrings[note[i]]) o[i][s];

minimize
  alpha_PC * d_PC * tot_PC +
  alpha_AT * d_AT * tot_AT +
  alpha_ST * d_ST * tot_ST + 
  alpha_DH * d_DH * tot_DH +
  alpha_NO * d_NO * tot_NO;

// ============================================================================
// 4. 制約条件 (Constraints)
// ============================================================================

subject to {
  // 基本制約
  forall(i in Notes) {
    // [変更] 有効な集合内の変数の和
    sum(s in Strings : s in OpenStrings[note[i]]) o[i][s] +
    sum(item in ValidPHCs[i]) y[i][item] == (note[i] != RestNote);

    // vinc2neg (不要な変数が生成されないため削除)

    vinc3:
      sum(p in HandPosition) x[i][p] == 1;

    // [変更] 有効な組み合わせに含まれる p だけを制約
    forall(item in ValidPHCs[i])
        y[i][item] <= x[i][item.p];
  }
  
  // --- ST制約: 許容範囲内に収める ---
  forall(i in Notes : note[i] != RestNote) {
      // 下限制約: y=0なら >= 0
      angleIndex[i] >= sum(item in ValidPHCs[i]) 
                           MinAngleIdxTable[item.p][item.h][item.c] * y[i][item];
                           
      // 上限制約: y=0なら <= 18
      angleIndex[i] <= sum(item in ValidPHCs[i]) 
                           MaxAngleIdxTable[item.p][item.h][item.c] * y[i][item] 
                           + MaxAngleIdx * (1 - sum(item in ValidPHCs[i]) y[i][item]);
  }
  
  // 到達不可除外 (変数が生成されないので削除)

  // --- 既存の制約群 ---
  forall(i in NotesButFirst)
    forall(p in HandPosition)
      vinc5:
        x[i][p] - x[i-1][p] <= 1 - sum(s in OpenStrings[note[i]]) o[i][s];

  forall(i in NotesButFirst) 
    vinc6_mod:
       if (note[i] != RestNote && prevNoteIndex[i] != i) 
          (PC[i] * timePerMm) <= accumulatedTime[i];


  // 1-2. 同音連打時のポジション移動禁止
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
    // [変更] 疎集合でループ
    forall(curr in ValidPHCs[i]) {
       y[i][curr] + 
       sum(prev in ValidPHCs[prevNoteIndex[i]] : 
            (curr.h == prev.h && 
             !((curr.c.corda == prev.c.corda) || (curr.c.fret == prev.c.fret && abs(curr.c.corda - prev.c.corda) == 1))
            )
       ) y[prevNoteIndex[i]][prev] <= 1;
    }
  }

  // ポジション移動を伴わないスライドの禁止
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i) {
    forall(curr in ValidPHCs[i]) {
       y[i][curr] + 
       sum(prev in ValidPHCs[prevNoteIndex[i]] : 
            (curr.c.corda == prev.c.corda && curr.c.fret != prev.c.fret)
       ) y[prevNoteIndex[i]][prev] <= 1;
    }
  }

  // ② 速弾き制約
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
    forall(curr in ValidPHCs[i]) {
       y[i][curr] + 
       sum(prev in ValidPHCs[prevNoteIndex[i]] : 
            (
              (curr.c.fret > prev.c.fret && curr.h < prev.h) ||
              (curr.c.fret < prev.c.fret && curr.h > prev.h) ||
              (curr.c.fret == prev.c.fret && curr.c.corda < prev.c.corda && curr.h < prev.h) ||
              (curr.c.fret == prev.c.fret && curr.c.corda > prev.c.corda && curr.h > prev.h)
            )
       ) y[prevNoteIndex[i]][prev] <= 1;
    }
  }

  // 同音連打時の指変更禁止
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isFast[i] == 1) {
      forall(curr in ValidPHCs[i]) {
           y[i][curr] + 
           sum(prev in ValidPHCs[prevNoteIndex[i]] : 
               (curr.c.corda == prev.c.corda && curr.c.fret == prev.c.fret && curr.h != prev.h)
           ) y[prevNoteIndex[i]][prev] <= 1;
      }
  }

  // ③ レガート制約
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isLegato[i] == 1) {
      forall(curr in ValidPHCs[i]) {
           y[i][curr] + 
           sum(prev in ValidPHCs[prevNoteIndex[i]] : 
               (curr.h == prev.h && curr.c.corda == prev.c.corda && curr.c.fret != prev.c.fret)
           ) y[prevNoteIndex[i]][prev] <= 1;
      }
  }

  // 3-2. アンカーの維持
  forall(i in NotesButFirst : note[i] != RestNote && prevNoteIndex[i] != i && isLegato[i] == 1) {
    forall(curr in ValidPHCs[i]) {
      y[i][curr] + 
         sum(prev in ValidPHCs[prevNoteIndex[i]] : 
             (curr.c.corda != prev.c.corda && curr.p != prev.p)
         ) y[prevNoteIndex[i]][prev] <= 1;
    }
  }
}

// ============================================================================
// 5. 出力設定 & 優先順位設定
// ============================================================================
main {
  cplex.tilim = 1000;
  
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
    writeln(">>> 解が見つかりませんでした。");
  }
}

execute {
  writeln("Note\tString\tFret\tHandposition\tFinger\tEffAngle");
  for (var i in Notes) {
    if (note[i] == RestNote) {
      write("R\t0\t0\t0\tx\t0");
    } else {
      write(MidiNames[note[i]], "\t");
      var found = 0;
      var isOpen = 0;
      for(var s in Strings) if(o[i][s]==1) { write(s,"\t0\t"); isOpen=1; }
      if(isOpen==0) {
         // [変更] タプルセットを反復
         for(var item in ValidPHCs[i]) 
            if(y[i][item]==1) write(item.c.corda,"\t",item.c.fret,"\t");
      }
      for(var p in HandPosition) if(x[i][p]==1) {
         write(p,"\t");
         if(isOpen==1) write("0");
         else {
            // [変更] タプルセットを反復
            for(var item in ValidPHCs[i]) 
               if(y[i][item]==1) {
                   write(item.h);
               }
         }
      }
      // 角度をインデックスから度数に戻して表示 (-5度刻み)
      var deg = -1.0 * angleIndex[i] * AngleStep;
      write("\t", deg);
    }
    writeln();
  }
  writeln();
  
writeln("\n--- Cost Breakdown ---");
  var costPC = alpha_PC * d_PC * tot_PC;
  var costAT = alpha_AT * d_AT * tot_AT;
  var costST = alpha_ST * d_ST * tot_ST;
  var costDH = alpha_DH * d_DH * tot_DH;
  var costNO = alpha_NO * d_NO * tot_NO;

  writeln("  Position Change (PC): ", costPC);
  writeln("  Angle Transition(AT): ", costAT);
  writeln("  Geo Stretch     (ST): ", costST);
  writeln("  Phys Action     (DH): ", costDH);
  writeln("  Open String     (NO): ", costNO);
  writeln("-----------------------------------------");
  writeln("  Total Cost (Sum)    : ", costPC + costAT + costST + costDH + costNO);
  writeln("-----------------------------------------");
}
