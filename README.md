# cpu-temp-limiter

It is rough and experimental and you should use it only if you review the code.

Main design goals:
* No dependencies except root and the things available in default Fedora/CentOS
* Allow the Intel SpeedStep overclocking when the computer is cool enough for snappy performance.
* Limit the CPU only when necessary.


```
# /path/to/cpu-temp-limit.sh --help
usage: ./path/to/cpu-temp-limit.sh -t 59
    where 59 is the target temperature (degrees celsius)
 
The maximum frequency and governor settings stay modified after the script is killed, but are lost after reboot.

```

It prints a lot of rubbish when run:

```
# /path/to/cpu-temp-limit.sh  -t 80
adding sensor /sys/class/thermal/thermal_zone0: 42000  acpitz  
adding sensor /sys/class/thermal/thermal_zone1: 20000  INT3400 Thermal  
adding sensor /sys/class/thermal/thermal_zone2: 31050  SEN1  
adding sensor /sys/class/thermal/thermal_zone3: 42050  B0D4  
adding sensor /sys/class/thermal/thermal_zone4: 42500  pch_skylake  
cat: /sys/class/thermal/thermal_zone5/temp: No data available
adding sensor /sys/class/thermal/thermal_zone5:   iwlwifi_1  
adding sensor /sys/class/thermal/thermal_zone6: 44000  x86_pkg_temp  
    reading temp from all sensors
cat: /sys/class/thermal/thermal_zone5/temp: No data available
temp = 43000
    freq = 804981
    under_target_percent = 46
balance_performance
powersave
    reading temp from all sensors
cat: /sys/class/thermal/thermal_zone5/temp: No data available
temp = 42500
    freq = 800006
    under_target_percent = 46
    reading temp from all sensors
cat: /sys/class/thermal/thermal_zone5/temp: No data available
temp = 43000
    freq = 800094
    under_target_percent = 46

...

temp = 44000
    freq = 2722878
    under_target_percent = 45
    reading temp from all sensors
cat: /sys/class/thermal/thermal_zone5/temp: No data available
temp = 46000
    freq = 2800064
    under_target_percent = 42
    reading temp from all sensors
cat: /sys/class/thermal/thermal_zone5/temp: No data available
cat: /sys/class/thermal/thermal_zone5/temp: No data available
    hottest_sensor_path=/sys/class/thermal/thermal_zone3/temp
temp = 47050
    freq = 900185
    under_target_percent = 41
temp = 43050
    freq = 800035
    under_target_percent = 46


```
