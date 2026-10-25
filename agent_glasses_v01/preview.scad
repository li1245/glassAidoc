$fn=48;
module part(name, c, v=[0,0,0]) {color(c) translate(v) import(str(name,".stl"),convexity=10);}
part("01_brow_frame",[0.16,0.20,0.25]);
part("02_left_temple",[0.18,0.22,0.27],[-14,-23,0]);
part("03_right_temple",[0.18,0.22,0.27],[14,-23,0]);
part("04_hud_pod",[0.12,0.34,0.46],[0,0,24]);
part("05_pod_lid",[0.2,0.55,0.75],[0,0,43]);
part("06_sliding_carriage",[0.95,0.58,0.16],[-10,0,28]);
part("07_combiner_frame",[0.25,0.75,0.65],[-28,0,23]);
part("08_nose_mount_left",[0.7,0.7,0.7],[0,0,-10]);
part("09_nose_mount_right",[0.7,0.7,0.7],[0,0,-10]);
