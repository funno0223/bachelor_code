/*********************************************
 * OPL 22.1.1.0 Model
 * Author: funno
 * Modified: Unified Logic & Slant Model
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
float timePerMm = ...;
float fingerLengths_mm[Fingers] = ...;
float fingerDifficulty[Fingers] = ...;
float timeThresholdRatio = ...;
float highPositionPenalty = ...;
float natural_min_spread_mm[FingersButFirst] = ...;

// --- 回転モデル用パラメータ ---
float knuckleOffsets[Fingers] = [0.0, 20.0, 40.0, 60.0]; 
float maxRotationAngle = 60.0; 

// 計算テーブル
float MaxReachTable[s in Strings][h in Fingers];
float NaturalReachTable[s in Strings][h in Fingers];
float HS_CostTable[p in HandPosition][h in Fingers][c in AllCombinations];
float EffectiveFingerLength[s in Strings][h in Fingers];

// コスト係数
float d_PC = ...;
float d_SC = ...;
float d_HS = ...;
float d_DH = ...;
float d_NO = ...;

float alpha_PC = ...;
float alpha_SC = ...;
float alpha_HS = ...;
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



// B. 指の回転(Slant)モデルによるリーチ & 有効指長計算
execute {
  var PI = 3.141592653589793;
  
  var full_SP_max = new Array();
  full_SP_max[1] = 0.0; 
  for(var f=2; f<=4; f++) {
     full_SP_max[f] = SP_max_mm[f];
  }
  
  var full_natural_min = new Array();
  full_natural_min[1] = 0.0;
  for(var f=2; f<=4; f++) {
     full_natural_min[f] = natural_min_spread_mm[f];
  }

  for (var s in Strings) {
    var angleDeg = maxRotationAngle * (s_max - s) / (s_max - 1);
    var angleRad = angleDeg * (PI / 180.0);
    
    var sinA = Math.sin(angleRad);
    var cosA = Math.cos(angleRad);
    var w = angleDeg / maxRotationAngle;

    for (var h = 1; h <= 4; h++) {
       // 1. X軸(フレット)方向のリーチ計算
       var geomReach = (knuckleOffsets[h] * sinA) + fingerLengths_mm[h];
       var calcMax = (1.0 - w) * full_SP_max[h] + w * geomReach;
       MaxReachTable[s][h] = calcMax;
       
       var geomNatural = (knuckleOffsets[h] * sinA) + (fingerLengths_mm[h] * 0.3);
       var calcNatural = (1.0 - w) * full_natural_min[h] + w * geomNatural;
       NaturalReachTable[s][h] = calcNatural;
       
       // 2. Y軸(弦)方向の有効指長計算
       EffectiveFingerLength[s][h] = fingerLengths_mm[h] * cosA;
    }
  }
  writeln("INFO: Slant Model & Effective Lengths Initialized.");
}

// C. HSコストテーブル生成
execute {
  var tolerance = 5.0; 
  for(var p in HandPosition) {
    for(var h in Fingers) { 
      for(var c in AllCombinations) {
        if (c.fret >= p) {
           var actualDist = fretPosition[c.fret] - fretPosition[p];
           var idealDist = NaturalReachTable[c.corda][h];
           var rawDiff = Math.abs(actualDist - idealDist);
           HS_CostTable[p][h][c] = Math.max(0.0, rawDiff - tolerance);
        } else {
           HS_CostTable[p][h][c] = 100000.0; 
        }
      }
    }
  }
  writeln("INFO: HS Cost Table updated with Tolerance (" + tolerance + "mm).");
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
dexpr float JointSavings[i in NotesButFirst] = 
  (note[i] == RestNote || prevNoteIndex[i] == i) ? 0.0 :
  sum(p in HandPosition)
  sum(h in Fingers : h == 1)
  sum(c in Combinations[note[i]])
  sum(c_prev in Combinations[note[prevNoteIndex[i]]] : 
      c.fret == c_prev.fret && abs(c.corda - c_prev.corda) >= 1)
    (stringSpacing * jointDiscountRate) * y[i][p][h][c] * y[prevNoteIndex[i]][p][h][c_prev];

// HS
dexpr float HS[i in Notes] = 
  (note[i] == RestNote) ? 0.0 : 
  sum(p in HandPosition) 
  sum(h in Fingers)
  sum(c in AllCombinations : c.fret >= p) 
    HS_CostTable[p][h][c] * y[i][p][h][c];

// DH
dexpr float DH[i in Notes] = 
  (note[i] == RestNote) ? 0.0 :
  sum(p in HandPosition) 
  sum(h in Fingers) 
  sum(c in Combinations[note[i]])
    ( 
      // 1. 基本コスト (常時適用)
      fingerDifficulty[h] - 1
      
      // 2. 弦方向へのリーチ不足
      + maxl(0, ((c.corda - 1) * stringSpacing) - EffectiveFingerLength[c.corda][h] * 0.8) 
      
    ) * y[i][p][h][c];

// 時間係数
dexpr float timePenaltyFactor[i in NotesButFirst] = 
  (note[i] == RestNote) ? 0.0 : 
  minl(1.0, 50.0 / (accumulatedTime[i] + 0.01)); 

// コスト総和
dexpr float tot_PC = sum(i in NotesButFirst) PC[i] * timePenaltyFactor[i];
dexpr float tot_SC = sum(i in NotesButFirst) SC[i] * timePenaltyFactor[i];
dexpr float tot_JointSavings = sum(i in NotesButFirst) JointSavings[i] * timePenaltyFactor[i];

dexpr float tot_HS = sum(i in Notes) HS[i];
dexpr float tot_DH = sum(i in Notes) DH[i];
dexpr float tot_NO = sum(i in Notes) sum(s in Strings : s in OpenStrings[note[i]]) o[i][s];

// --- MODEL ---

minimize
  alpha_PC * d_PC * tot_PC +
  alpha_SC * d_SC * (tot_SC - tot_JointSavings) + 
  alpha_HS * d_HS * tot_HS +
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
  
  // --- リーチ制約 ---
  forall(i in Notes) {
    forall(p in HandPosition) {
      forall(h in FingersButFirst)
        forall(c in AllCombinations : c.fret >= p)
          vinc7:
             (fretPosition[c.fret] - fretPosition[p]) * y[i][p][h][c] <= MaxReachTable[c.corda][h];

      forall(h in FingersButFirst)
        forall(c in AllCombinations)
          vinc8:
            (c.fret - p - h + 1) * y[i][p][h][c] >= 0;

      forall(c in AllCombinations : c.fret >= p)
        vinc9:
           (fretPosition[c.fret] - fretPosition[p]) * y[i][p][1][c] <= MaxReachTable[c.corda][1];

      forall(c in AllCombinations : c.fret < p)
         vinc9a:
            y[i][p][1][c] == 0;
    }
  }

  // =========================================================================
  // 遷移制約
  // =========================================================================
  
  // --- A. ハード制約: 物理的に不可能な動き (常に適用) ---
  // 条件: 音符が存在し、前の音が存在する場合のみ生成
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
  
  var costPC = alpha_PC * d_PC * tot_PC;
  var costSC = alpha_SC * d_SC * (tot_SC - tot_JointSavings); // 出力にも割引を反映
  var costHS = alpha_HS * d_HS * tot_HS;
  var costDH = alpha_DH * d_DH * tot_DH;
  var costNO = alpha_NO * d_NO * tot_NO;
  
  writeln("  Position Change (PC): ", costPC);
  writeln("  String Change   (SC): ", costSC);
  writeln("  Hand Spread     (HS): ", costHS);
  writeln("  Difficulty Hold (DH): ", costDH);
  writeln("  Open String     (NO): ", costNO);
  writeln("-----------------------------------------");
  writeln("  Total Cost (Sum)    : ", costPC+costSC+costHS+costDH+costNO);
  writeln("-----------------------------------------");
}