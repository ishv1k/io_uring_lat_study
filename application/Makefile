# Makefile to build various testing programs for Homa.

# The paper used gcc/g++ 11.4.0; the system default on nexus03 is 10.5.
CC := gcc-11
CXX := g++-11

CFLAGS := -pthread -Wall -Werror -g -fno-strict-aliasing -O3 -I..


BINS := latency_client latency_server latency_client_cores latency_server_cores latency_client_imbalanced

OBJS := $(patsubst %,%.o,$(BINS))
	
LIB_SRCS := test_utils.cc
LIB_OBJS := $(patsubst %.c,%.o,$(patsubst %.cc,%.o,$(LIB_SRCS)))
	
.SECONDARY: $(OBJS) $(LIB_OBJS)

all: $(BINS)

cp_node: cp_node.o dist.o $(LIB_OBJS)
	$(CXX) $(CFLAGS) $^ -lpthread -o $@

# This seems to be the only way to disable the built-in implicit rules
# for %:%.c and %:%.cc.
.SUFFIXES:
	
%: %.o $(LIB_OBJS)
	$(CXX) $(CFLAGS) $^ -lpthread -o $@
	
%.o: %.cc test_utils.h 
	$(CXX) -c $(CFLAGS) -std=c++17 $< -o $@
	
%.o: %.c test_utils.h 
	$(CC) -c $(CFLAGS) $< -o $@
	
# homa_api.o: ../homa_api.c
# 	cc -c $(CFLAGS) $< -o $@

clean:
	rm -f $(BINS) $(OBJS) $(LIB_OBJS)

# The following target is useful for debugging Makefiles; it
# prints the value of a make variable.
print-%:
	@echo $* = $($*)
	
