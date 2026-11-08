#pragma once
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
int VMMThinRuntimePrint(const char *format,...);
int VMMThinRuntimeFPrint(FILE *stream,const char *format,...);
void VMMThinRuntimeRecord(const char *kind,uint32_t opcode,uint32_t stamp,size_t bytes,uint32_t slot);
