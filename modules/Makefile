obj-m = vruntime_probe.o softirq_packets.o program_pmu.o packet_dist.o
KVERSION = $(shell uname -r)
# Must match the compiler the 5.10.46 kernels were built with (gcc-11).
KCC ?= gcc-11

# Per-host CPU filter (both hyperthreads of the measured core). nexus01 is the server.
ifeq ($(shell hostname -s),nexus01)
ccflags-y += -DCOUNTING_SERVER_SIDE -DFILTER_CPU_A=65 -DFILTER_CPU_B=193
else
ccflags-y += -DFILTER_CPU_A=1 -DFILTER_CPU_B=65
endif

all:
		make -C /lib/modules/$(KVERSION)/build M=$(PWD) CC=$(KCC) HOSTCC=$(KCC) modules
clean:
		make -C /lib/modules/$(KVERSION)/build M=$(PWD) CC=$(KCC) HOSTCC=$(KCC) clean
