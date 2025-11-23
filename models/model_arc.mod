/*********************************************
 * OPL 22.1.1.0 Model
 * Author: funno
 * Modified for Optimization & Constraints
 *********************************************/
using CPLEX;

// --- データ定義 (変更なし) ---
int RestNote = 
int f_max = ...;
int s_max = ...;
range Frets = 1..f_max;
range Strings = 1..s_max;
{string} PlayableSounds = ...;
tuple combination { int corda; int fret; }
{combination} AllCombinations = {<s,f> | s in Strings, f in Frets};
{int} OpenStrings[PlayableSounds] = ...;
{combination} Combinations[PlayableSounds] = ...;
int m = ...;
range Notes = 1..m;
range NotesButFirst = 2..m;
string note[Notes] = ...;
float availableTime[Notes] = ...;
range Fingers = 1..4;
range FingersButFirst = 2..4;
range HandPosition = 1..f_max;

// パラメータ群
float scaleLength = ...;
float fretPosition[Frets];
float stringSpacing = ...;
float SP_max_mm[FingersButFirst] = ...;
float timePerMm = ...;
float fingerLengths_mm[Fingers] = ...;
float fingerDifficulty[Fingers] = ...;
float timeThresholdRatio = ...;
float highPositionPenalty = ...;
float connectedTimeThreshold = ...;
float M_value = ...;
float natural_min_spread_mm[FingersButFirst] = ...;
float rest_pc_discount = ...;
float slide_pc_discount = 0.7;

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

execute {
    for (var f in Frets) {
        fretPosition[f] = scaleLength - (scaleLength / Math.pow(2, f / 12.0));
    }
}

// 変数定義
dvar boolean o[Notes][Strings];
dvar boolean y[Notes][HandPosition][Fingers][AllCombinations];
dvar boolean x[Notes][HandPosition];
dvar float cost_PC[i in NotesButFirst];
dvar float cost_SC[i in NotesButFirst];
dvar boolean reduce_cost[i in NotesButFirst];
dvar boolean is_slide[i in NotesButFirst];

// 式定義
dexpr float PC[i in NotesButFirst] =
    abs(sum(p in HandPosition) fretPosition[p] * x[i-1][p] -
        sum(p in HandPosition) fretPosition[p] * x[i][p]);

dexpr float SC[i in NotesButFirst] =
    stringSpacing * abs(
        sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) c.corda * y[i-1][p][h][c] -
        sum(p in HandPosition) sum(h in Fingers) sum(c in AllCombinations) c.corda * y[i][p][h][c] +
        sum(s in OpenStrings[note[i-1]]) s * o[i-1][s] -
        sum(s in OpenStrings[note[i]]) s * o[i][s]);

dexpr float HS[i in Notes] =
    sum(p in HandPosition)
    sum(h in FingersButFirst)
    sum(c in AllCombinations : c.fret >= p)
        maxl(0, (fretPosition[c.fret] - fretPosition[p]) - natural_min_spread_mm[h]) *
        y[i][p][h][c];

dexpr float DH[i in Notes] =
    sum(p in HandPosition)
    sum(h in Fingers)
    sum(c in Combinations[note[i]])
        (maxl(0, ((c.corda - 1) * stringSpacing) - fingerLengths_mm[h] * 0.8) *
         fingerDifficulty[h] +
         maxl(0, c.fret - 16.0) * highPositionPenalty) *
        y[i][p][h][c];

dexpr float required_PC_Time[i in NotesButFirst] = PC[i] * timePerMm;
dexpr float required_SC_Time[i in NotesButFirst] = SC[i] * timePerMm;
dexpr float totalRequiredTime[i in NotesButFirst] = required_PC_Time[i] + required_SC_Time[i];

dexpr float tot_PC = sum(i in NotesButFirst) cost_PC[i];
dexpr float tot_SC = sum(i in NotesButFirst) cost_SC[i];
dexpr float tot_HS = sum(i in Notes) HS[i];
dexpr float tot_DH = sum(i in Notes) DH[i];
dexpr float tot_NO = sum(i in Notes) sum(s in Strings : s in OpenStrings[note[i]]) o[i][s];

// --- MODEL ---
minimize
    alpha_PC * d_PC * tot_PC +
    alpha_SC * d_SC * tot_SC +
    alpha_HS * d_HS * tot_HS +
    alpha_DH * d_DH * tot_DH +
    alpha_NO * d_NO * tot_NO;

subject to {
    forall(i in NotesButFirst : availableTime[i] < 200) {
         abs(sum(p in HandPosition) x[i][p]*p - sum(p in HandPosition) x[i-1][p]*p) <= 5;
    }

    // 既存の制約群
    forall(i in Notes)
        vinc2: sum(s in Strings : s in OpenStrings[note[i]]) o[i][s] +
               sum(p in HandPosition) sum(h in Fingers) sum(c in Combinations[note[i]]) y[i][p][h][c] == 1;

    forall(i in Notes)
        vinc2neg: sum(p in HandPosition) sum(h in Fingers)
                  sum(c in AllCombinations : c not in Combinations[note[i]]) y[i][p][h][c] == 0;

    forall(i in Notes)
        vinc3: sum(p in HandPosition) x[i][p] == 1;

    forall(i in Notes)
        forall(p in HandPosition)
            vinc4: sum(h in Fingers) sum(c in AllCombinations) y[i][p][h][c] <= x[i][p];

    forall(i in NotesButFirst)
        forall(p in HandPosition)
            vinc5: x[i][p] - x[i-1][p] <= 1 - sum(s in OpenStrings[note[i]]) o[i][s];
            
    forall(i in NotesButFirst)
        vinc6:
            timePerMm * PC[i] <= availableTime[i];

    forall(i in Notes)
        forall(p in HandPosition)
            forall(h in FingersButFirst)
                forall(c in AllCombinations : c.fret >= p)
                    vinc7: (fretPosition[c.fret] - fretPosition[p]) * y[i][p][h][c] <= SP_max_mm[h];

    forall(i in Notes)
        forall(p in HandPosition)
            forall(h in FingersButFirst)
                forall(c in AllCombinations)
                    vinc8_min_spread: (natural_min_spread_mm[h] * y[i][p][h][c]) <=
                                      (fretPosition[c.fret] - fretPosition[p]) * y[i][p][h][c];

    forall(i in Notes)
        forall(p in HandPosition)
            forall(c in AllCombinations)
                vinc9: (c.fret - p) * y[i][p][1][c] == 0;

forall(i in NotesButFirst)
        forall(h in Fingers)
            forall(c in AllCombinations)
                vinc10c: 
                    sum(p in HandPosition) 
                    sum(c1 in AllCombinations : c1.fret != c.fret) // フレットが違えば同じ指はダメ
                    y[i][p][h][c1] 
                    <= 1 - sum(p in HandPosition) y[i-1][p][h][c];

    forall(i in NotesButFirst)
        forall(c in Combinations[note[i]] inter Combinations[note[i-1]])
            forall(h in Fingers)
                sum(p in HandPosition) y[i][p][h][c] +
                sum(p in HandPosition) sum(h2 in Fingers : h2 != h) y[i-1][p][h2][c] <= 1;

    // スライド・コスト計算ロジック
    forall(i in NotesButFirst : availableTime[i] >= connectedTimeThreshold)
        ct_slide_time_check: is_slide[i] == 0;

    forall(i in NotesButFirst : availableTime[i] < connectedTimeThreshold)
        ct_slide_sc_check: SC[i] <= M_value * (1 - is_slide[i]);

    forall(i in NotesButFirst : availableTime[i] < connectedTimeThreshold)
        logic_A_connected: reduce_cost[i] == 0;

    forall(i in NotesButFirst : availableTime[i] >= connectedTimeThreshold)
        logic_B_rest_M: (totalRequiredTime[i] * timeThresholdRatio) - availableTime[i]
                        <= M_value * (1 - reduce_cost[i]);

    forall(i in NotesButFirst) {
        assign_cost_PC_full: cost_PC[i] >= PC[i] - M_value * (reduce_cost[i] + is_slide[i]);
        assign_cost_PC_full_up: cost_PC[i] <= PC[i] + M_value * (reduce_cost[i] + is_slide[i]);
        assign_cost_PC_reduced: cost_PC[i] >= (PC[i] * rest_pc_discount) - M_value * (1 - reduce_cost[i]);
        assign_cost_PC_reduced_up: cost_PC[i] <= (PC[i] * rest_pc_discount) + M_value * (1 - reduce_cost[i]);
        assign_cost_PC_slide: cost_PC[i] >= (PC[i] * slide_pc_discount) - M_value * (1 - is_slide[i]);
        assign_cost_PC_slide_up: cost_PC[i] <= (PC[i] * slide_pc_discount) + M_value * (1 - is_slide[i]);

        assign_cost_SC_reduced: cost_SC[i] >= (SC[i] * rest_pc_discount) - M_value * (1 - reduce_cost[i]);
        assign_cost_SC_reduced_up: cost_SC[i] <= (SC[i] * rest_pc_discount) + M_value * (1 - reduce_cost[i]);
        assign_cost_SC_full: cost_SC[i] >= SC[i] - M_value * reduce_cost[i];
        assign_cost_SC_full_up: cost_SC[i] <= SC[i] + M_value * reduce_cost[i];
        
        cost_PC[i] >= 0;
        cost_SC[i] >= 0;
    }
}

// --- MAIN BLOCK (制御・実行) ---
main {
    // 2. 許容Gap: 5% (0.05)
    cplex.epgap = 0.05;
    
    // 3. 探索強調
    cplex.mipemphasis = 4; 
    
    thisOplModel.generate();
    if (cplex.solve()) {
        writeln(">>> 解が見つかりました。");
        
        // 目的関数値の取得
        var obj = cplex.getObjValue();
        writeln(">>> Objective: ", obj);
        
        // getMipRelativeGap() がエラーになるため、BestBoundとObjectiveから手動計算します
        var bestBound = cplex.getBestObjValue();
        var gap = 0.0;
        
        // ゼロ除算防止
        if (Math.abs(obj) > 0.000001) {
             gap = Math.abs(obj - bestBound) / (0.0000001 + Math.abs(obj));
        }
        writeln(">>> Gap (Approx): ", gap * 100, "%");
        // -------------------------------
        
        // 結果表示用の execute ブロックを実行
        thisOplModel.postProcess();
    } else {
        writeln(">>> 解が見つかりませんでした。");
    }
}


// --- EXECUTE BLOCK (結果表示) ---
execute {
    // OUTPUT 1: Detailed fingering table
    writeln("Note\tString\tFret\tHandposition\tFinger");
    for (i in Notes) {
        write(note[i], "\t");

        // Check open strings
        for (s in Strings) {
            if (o[i][s] == 1) {
                write(s, "\t0\t");
            }
        }

        // Check combinations
        for (p in Frets) {
            for (h in Fingers) {
                for (c in AllCombinations) {
                    if (y[i][p][h][c] == 1) {
                        write(c.corda, "\t", c.fret, "\t");
                    }
                }
            }
        }

        // Hand position and finger
        var found = 0;
        for (p in Frets) {
            if (x[i][p] == 1) {
                write(p, "\t");
                for (h in Fingers) {
                    for (c in AllCombinations) {
                        if (y[i][p][h][c] == 1) {
                            write(h, "\t");
                            found = 1;
                        }
                    }
                }
            }
        }

        if (found == 0)
            write("x\t");

        writeln();
    }

    writeln();

    // OUTPUT 2: String numbers
    for (i in Notes) {
        for (s in Strings) {
            if (o[i][s] == 1)
                write(s, ",");
        }
        for (p in Frets) {
            for (h in Fingers) {
                for (c in AllCombinations) {
                    if (y[i][p][h][c] == 1)
                        write(c.corda, ",");
                }
            }
        }
    }
    writeln();

    // OUTPUT 3: Fret numbers
    for (i in Notes) {
        var trovato = 0;
        for (p in Frets) {
            for (h in Fingers) {
                for (c in AllCombinations) {
                    if (y[i][p][h][c] == 1) {
                        write(c.fret, ",");
                        trovato = 1;
                    }
                }
            }
        }
        if (trovato == 0)
            write("0,");
    }
    writeln();

    // OUTPUT 4: Finger assignments
    for (i in Notes) {
        var found = 0;
        for (p in Frets) {
            for (h in Fingers) {
                for (c in AllCombinations) {
                    if (y[i][p][h][c] == 1) {
                        write(h, ",");
                        found = 1;
                    }
                }
            }
        }
        if (found == 0)
            write("0,");
    }
    writeln();

    // OUTPUT 5: Cost breakdown
    writeln("\n--- 特徴量コストの内訳 (最適解) ---");

    var costPC = alpha_PC * d_PC * tot_PC;
    var costSC = alpha_SC * d_SC * tot_SC;
    var costHS = alpha_HS * d_HS * tot_HS;
    var costDH = alpha_DH * d_DH * tot_DH;
    var costNO = alpha_NO * d_NO * tot_NO;
    var totalCost = costPC + costSC + costHS + costDH + costNO;

    writeln("  Position Change (PC) Cost: " + costPC);
    writeln("  String Change (SC) Cost: " + costSC);
    writeln("  Hand Spread (HS) Cost:   " + costHS);
    writeln("  Difficulty Hold (DH) Cost: " + costDH);
    writeln("  Open String (NO) Cost:   " + costNO);
    writeln("-----------------------------------------");
    writeln("  Total Cost (Sum):        " + totalCost);
    writeln("  (この値はOBJECTIVE値と一致します)");
    writeln("-----------------------------------------");
}