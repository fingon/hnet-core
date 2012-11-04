set terminal pdf;
set output "foo.pdf";
set ylabel "#";
set xlabel "Time";
set yrange [0:];
set y2range [0:];
set grid xtics;
set grid ytics;
set y2tics autofreq;
show y2tics;

plot "file0.dat" using 1:2 title "file0" with lines,\
 "file1.dat" using 1:2 title "file1" with lines axes x1y2;
