/*
 * Minimal DXBC (shader model < 6) disassembler host.
 * Calls D3DDisassemble from d3dcompiler_47.dll, which is what RenoDX uses for
 * SM<6 bytecode (see src/utils/shader_compiler_directx.hpp: DisassembleShaderFXC).
 * DXC can only read DXIL containers, so it cannot disassemble these captures.
 *
 * Build (cross-compile):  x86_64-w64-mingw32-gcc -O2 -o dxbc-disasm.exe dxbc-disasm.c
 * Run (CrossOver/Wine):   wine --bottle <bottle> dxbc-disasm.exe input.cso [output.asm]
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

/* Minimal ID3DBlob vtable: IUnknown (3) + GetBufferPointer + GetBufferSize. */
typedef struct ID3DBlob ID3DBlob;
struct ID3DBlob {
  const struct ID3DBlobVtbl* lpVtbl;
};
struct ID3DBlobVtbl {
  HRESULT(STDMETHODCALLTYPE* QueryInterface)(ID3DBlob*, const void*, void**);
  ULONG(STDMETHODCALLTYPE* AddRef)(ID3DBlob*);
  ULONG(STDMETHODCALLTYPE* Release)(ID3DBlob*);
  void*(STDMETHODCALLTYPE* GetBufferPointer)(ID3DBlob*);
  SIZE_T(STDMETHODCALLTYPE* GetBufferSize)(ID3DBlob*);
};

typedef HRESULT(WINAPI* D3DDisassembleFn)(LPCVOID, SIZE_T, UINT, LPCSTR, ID3DBlob**);

/* D3DDisassemble flag values (d3dcompiler.h). 0x01 is ENABLE_COLOR_CODE, which
 * emits HTML; instruction numbering/offset are 0x04/0x20. */
#define D3D_DISASM_ENABLE_INSTRUCTION_NUMBERING 0x04
#define D3D_DISASM_ENABLE_INSTRUCTION_OFFSET 0x20

static unsigned char* read_file(const char* path, SIZE_T* size) {
  FILE* fp = fopen(path, "rb");
  if (fp == NULL) { fprintf(stderr, "Cannot open %s\n", path); return NULL; }
  fseek(fp, 0, SEEK_END);
  long length = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (length <= 0) { fclose(fp); fprintf(stderr, "Empty file %s\n", path); return NULL; }
  unsigned char* data = (unsigned char*)malloc((size_t)length);
  if (data == NULL || fread(data, 1, (size_t)length, fp) != (size_t)length) {
    fclose(fp); free(data); fprintf(stderr, "Read failed %s\n", path); return NULL;
  }
  fclose(fp);
  *size = (SIZE_T)length;
  return data;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s input.cso [output.asm]\n", argv[0]);
    return 2;
  }

  SIZE_T size = 0;
  unsigned char* data = read_file(argv[1], &size);
  if (data == NULL) return 1;

  /* Reject non-DXBC input rather than guessing at the container. */
  if (size < 4 || memcmp(data, "DXBC", 4) != 0) {
    fprintf(stderr, "%s: not a DXBC container (expected magic 'DXBC').\n", argv[1]);
    if (size >= 4 && memcmp(data, "DXIL", 4) == 0) {
      fprintf(stderr, "This file is DXIL; use 'dxc -dumpbin' instead.\n");
    }
    free(data);
    return 1;
  }

  HMODULE dll = LoadLibraryA("d3dcompiler_47.dll");
  if (dll == NULL) { fprintf(stderr, "Could not load d3dcompiler_47.dll\n"); free(data); return 1; }
  D3DDisassembleFn disassemble = (D3DDisassembleFn)GetProcAddress(dll, "D3DDisassemble");
  if (disassemble == NULL) {
    fprintf(stderr, "d3dcompiler_47.dll has no D3DDisassemble export.\n");
    free(data);
    return 1;
  }

  ID3DBlob* blob = NULL;
  HRESULT hr = disassemble(data, size,
                           D3D_DISASM_ENABLE_INSTRUCTION_NUMBERING |
                               D3D_DISASM_ENABLE_INSTRUCTION_OFFSET,
                           NULL, &blob);
  if (FAILED(hr) || blob == NULL) {
    fprintf(stderr, "D3DDisassemble failed (hr=0x%08lX)\n", (unsigned long)hr);
    free(data);
    return 1;
  }

  const char* text = (const char*)blob->lpVtbl->GetBufferPointer(blob);
  SIZE_T text_size = blob->lpVtbl->GetBufferSize(blob);
  if (argc >= 3) {
    FILE* out = fopen(argv[2], "wb");
    if (out == NULL) { fprintf(stderr, "Cannot write %s\n", argv[2]); }
    else { fwrite(text, 1, text_size, out); fclose(out); }
  }
  fwrite(text, 1, text_size, stdout);

  blob->lpVtbl->Release(blob);
  free(data);
  return 0;
}