# Charts for hardware/results/, drawn from the CSVs written by results.nim.
#   gnuplot -e "dir='hardware/results/'" hardware/plots.gp

if (!exists("dir")) dir = 'hardware/results/'
set datafile separator ','
set terminal svg size 760,440 dynamic enhanced font 'sans,12' background rgb '#fcfcfb'

# Validated categorical palette (colourblind-safe in this order)
c1 = '#2a78d6'; c2 = '#eb6834'; c3 = '#1baf7a'; c4 = '#eda100'
set border 3 lc rgb '#c3c2b7'
set tics nomirror textcolor rgb '#898781'
set grid ytics lc rgb '#e1e0d9' lw 1 dt 1
set key top left horizontal textcolor rgb '#52514e' samplen 2
set title font 'sans,15' textcolor rgb '#0b0b0b'
set xlabel textcolor rgb '#52514e'
set ylabel textcolor rgb '#52514e'

# ---- 1. divider accuracy ----------------------------------------------------
set output dir.'divider-accuracy.svg'
set title "Divider error across the game\n{/*0.8 Every simulated case: cards left 1–40 × danger 0/25/50/75/100 %}"
set xlabel 'cards left'
set ylabel 'error (% of full scale)'
set xrange [0:41]
set yrange [-0.1:0.1]
set key off
plot dir.'divider-accuracy.csv' skip 1 using 1:5 with points pt 7 ps 0.8 lc rgb c1 title 'divider', \
     0 with lines dt 2 lc rgb '#898781' notitle
set key on

# ---- 2. divider settling ------------------------------------------------------
set output dir.'divider-settling.svg'
set title "Divider settling after power-up\n{/*0.8 Output vs time, all four cases targeting 50 %. Dashed = target.}"
set xlabel 'time (ms)'
set ylabel 'output (%)'
set xrange [0:300]
set yrange [0:100]
set key bottom right vertical
colours = c1.' '.c2.' '.c3.' '.c4
cases = '40 10 4 2'
plot for [i=1:4] dir.'divider-settling.csv' skip 1 \
       using ($1 == word(cases, i) + 0 ? $2 : NaN):3 with lines lw 2 \
       lc rgb word(colours, i) title word(cases, i).' cards left', \
     50 with lines dt 2 lc rgb '#898781' notitle

# ---- 3. whole chain vs app ----------------------------------------------------
set output dir.'chain-vs-app.svg'
set title "Whole analog chain vs the app\n{/*0.8 Plates → 40 detector bits → popcount → DACs → subtractors → divider, in ngspice}"
set xlabel 'scenario (see table in README)'
set ylabel 'danger chance, next card (%)'
set autoscale x
set yrange [0:120]
set ytics 0,20,100
set key top left horizontal
set style data histogram
set style histogram clustered gap 1
set style fill solid 1.0 border rgb '#fcfcfb'
set boxwidth 0.9
plot dir.'chain-vs-app.csv' skip 1 using 7:xtic(1) lc rgb c1 title 'app (odds.nim)', \
     '' skip 1 using 8 lc rgb c2 title 'circuit (ngspice)'

# ---- 4. resistor tolerance ----------------------------------------------------
set output dir.'resistor-tolerance.svg'
set title "Resistor tolerance late in the game\n{/*0.8 500 random builds each. Void stacked, 30 played, 24 danger played: 8 of 10 left = 80 %}"
set xlabel 'error (% of full scale)'
set ylabel 'builds per 0.1 % bin'
set style data boxes
binwidth = 0.1
bin(x) = binwidth * floor(x / binwidth + 0.5)
set xrange [-1.6:1.6]
set autoscale y
set yrange [0:*]
set boxwidth binwidth * 0.9
set style fill transparent solid 0.6 noborder
set key top left horizontal
plot dir.'resistor-tolerance.csv' skip 1 using (bin($4)):($1 == 1 ? 1 : 0) \
       smooth freq with boxes lc rgb c1 title '0.1 % everywhere', \
     '' skip 1 using (bin($4)):($1 == 2 ? 1 : 0) \
       smooth freq with boxes lc rgb c2 title '0.1 % + 0.01 % matched pairs'
