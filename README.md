# cpu-temp-limiter

It is rough and experimental and you should use it only if you review the code.

Main design goals:
* No dependencies except root and the things available in default Fedora/CentOS
* Allow the Intel SpeedStep overclocking when the computer is cool enough for snappy performance.
* Limit the CPU only when necessary.
* Partition programs so that they can try to hog the CPU without hurting performance of other programs (e.g. I don't care Spideroak is slow, but I do care about Firefox being snappy). The partitioning is done using the `cpuset` cgroup and not using the `cpu` cgroup because during my testing I found out `cpu` limiting doesn't play nice with Bluejeans and PulseAudio.
* Burn out the CPU cores evenly.


```
# /path/to/cpu-temp-limit.sh --help
usage: ./path/to/cpu-temp-limit.sh -t 59 [-r 69 5] [-n] [-p]
    where 59 is the target temperature (degrees celsius)
    -r 69 5 - allow temperature to rise up to 69 for up to 5 minutes per hour
    -n - do not create cgroups
    -p - do not require intel pstate
 
The maximum frequency settings stay after the script is killed, but are lost after reboot.

```

It prints a lot of rubbish when run:

```
# /path/to/cpu-temp-limit.sh -t 59 -r 69 10
allowing temp 69 for up to 10 min per hour
cgdelete: cannot remove group '/temp_limiter_cpu_a': No such file or directory
cgdelete: cannot remove group '/temp_limiter_cpu_b': No such file or directory
cgdelete: cannot remove group '/temp_limiter_cpu_c': No such file or directory
cgdelete: cannot remove group '/temp_limiter_cpu_d': No such file or directory
cgdelete: cannot remove group '/temp_limiter_cpu_e': No such file or directory
cgdelete: cannot remove group '/temp_limiter_cpu_r': No such file or directory
B
1
2
declare -a RND_CORE=([0]="2" [1]="6" [2]="3" [3]="7" [4]="0" [5]="4" [6]="1" [7]="5")
adding sensor /sys/class/thermal/thermal_zone0: 54000  acpitz  
adding sensor /sys/class/thermal/thermal_zone1: 20000  INT3400 Thermal  
adding sensor /sys/class/thermal/thermal_zone2: 42000  SEN1  
adding sensor /sys/class/thermal/thermal_zone3: 54500  pch_skylake  
adding sensor /sys/class/thermal/thermal_zone4: 54000  B0D4  
adding sensor /sys/class/thermal/thermal_zone5: 51000  x86_pkg_temp  
temp = 55000
temp = 55000 ; freq = 800013
    max freq = 4200000
    temp_under_target_relative_percent = 6
    max_freq_khz_change=882000
    new_max_freq_khz=5082000
balance_performance
powersave
temp = 54000
    max freq = 4200000
    temp_under_target_relative_percent = 8
    max_freq_khz_change=1176000
    new_max_freq_khz=5376000
temp = 53500
    max freq = 4200000
    temp_under_target_relative_percent = 9
    max_freq_khz_change=1323000
    new_max_freq_khz=5523000
    re-setting cpu affinity for all processes
        [ffox] group_a_cores=2,6
        [TODO] group_b_cores=3,7
        [spdr] group_c_cores=3,7
        [chrm] group_d_cores=3,7,0,4
        [work] group_e_cores=3,7,0,4,1,5
        [rest] group_r_cores=0,4,1,5
    done
temp = 53000
    max freq = 4200000
    temp_under_target_relative_percent = 10
    max_freq_khz_change=1470000
    new_max_freq_khz=5670000
temp = 57000
    max freq = 4200000
    temp_under_target_relative_percent = 3
    max_freq_khz_change=441000 below hysteresis threshold
balance_power
powersave
temp = 52000
    max freq = 4200000
    temp_under_target_relative_percent = 11
    max_freq_khz_change=1617000
    new_max_freq_khz=5817000
temp = 76000
    max freq = 4200000
    allowing higher temperature limit; 0 mins used so far
    temp_under_target_relative_percent = -10
    max_freq_khz_change=-4410000
    new_max_freq_khz=-210000
700000
power
powersave
temp = 52000
    max freq = 700000
    temp_under_target_relative_percent = 11
    max_freq_khz_change=269500
    new_max_freq_khz=969500
969500
balance_performance
powersave
temp = 53000
    max freq = 969500
    temp_under_target_relative_percent = 10
    max_freq_khz_change=339325
    new_max_freq_khz=1308825
1308825
temp = 52500
temp = 52500 ; freq = 1300044
    max freq = 1308825
    temp_under_target_relative_percent = 11
    max_freq_khz_change=503897
    new_max_freq_khz=1812722
1812722
temp = 53000
    max freq = 1812722
    temp_under_target_relative_percent = 10
    max_freq_khz_change=634452
    new_max_freq_khz=2447174
2447174
temp = 60000
    max freq = 2447174
    temp_under_target_relative_percent = -1
    max_freq_khz_change=-256953 below hysteresis threshold
balance_power
powersave
temp = 56000
    max freq = 2447174
    temp_under_target_relative_percent = 5
    max_freq_khz_change=428255
    new_max_freq_khz=2875429
2875429
balance_performance
powersave
temp = 54000
    max freq = 2875429
    temp_under_target_relative_percent = 8
    max_freq_khz_change=805120
    new_max_freq_khz=3680549
3680549


```
