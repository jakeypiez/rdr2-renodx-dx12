/*
 * Minimal HLSL -> DXBC compiler host for shader model 5.x.
 * Uses D3DCompile from d3dcompiler_47.dll (the API FXC wraps), so SM5.1 DXBC can
 * be produced without the Windows SDK's fxc.exe. DXC is NOT usable here: it
 * promotes ps_5_1 to a 6.0 DXIL container.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o hlsl-compile.exe hlsl-compile.c
 * Run:   wine --bottle <bottle> hlsl-compile.exe in.hlsl out.cso <target> [entry]
 *        e.g. hlsl-compile.exe out.hlsl out.cso ps_5_1 main
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

typedef HRESULT(WINAPI* D3DCompileFn)(LPCVOID, SIZE_T, LPCSTR, const void*, void*,
                                      LPCSTR, LPCSTR, UINT, UINT, ID3DBlob**, ID3DBlob**);

/* Minimal ID3DInclude declaration (d3dcompiler.h is not used here so this host
   stays self-contained for the MinGW cross-build). Layout matches the SDK. */
typedef enum D3D_INCLUDE_TYPE { D3D_INCLUDE_LOCAL = 0, D3D_INCLUDE_SYSTEM = 1 } D3D_INCLUDE_TYPE;
typedef struct ID3DInclude ID3DInclude;
/* Must mirror DECLARE_INTERFACE: IUnknown's three methods come first, then Open
   and Close. Omitting them misaligns the vtable and crashes the compiler. */
struct ID3DInclude {
  HRESULT(STDMETHODCALLTYPE* QueryInterface)(ID3DInclude*, const void*, void**);
  ULONG(STDMETHODCALLTYPE* AddRef)(ID3DInclude*);
  ULONG(STDMETHODCALLTYPE* Release)(ID3DInclude*);
  HRESULT(STDMETHODCALLTYPE* Open)(ID3DInclude*, D3D_INCLUDE_TYPE, LPCSTR, LPCVOID, LPCVOID*, UINT*);
  HRESULT(STDMETHODCALLTYPE* Close)(ID3DInclude*, LPCVOID);
};

static HRESULT STDMETHODCALLTYPE IncludeQueryInterface(ID3DInclude* this_ptr, const void* riid, void** out) {
  (void)this_ptr; (void)riid; (void)out; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE IncludeAddRef(ID3DInclude* this_ptr) { (void)this_ptr; return 1; }
static ULONG STDMETHODCALLTYPE IncludeRelease(ID3DInclude* this_ptr) { (void)this_ptr; return 1; }

#define D3DCOMPILE_ENABLE_STRICTNESS 0x00000800
#define D3DCOMPILE_OPTIMIZATION_LEVEL3 0x00008000

/* Resolve #include relative to the including file's directory. */
static HRESULT STDMETHODCALLTYPE IncludeOpen(ID3DInclude* this_ptr, D3D_INCLUDE_TYPE type,
                                             LPCSTR filename, LPCVOID parent_data,
                                             LPCVOID* data, UINT* bytes) {
  char path[MAX_PATH];
  char parent[MAX_PATH];
  FILE* fp;
  long size;

  (void)this_ptr; (void)type;

  if (parent_data != NULL) {
    strncpy(parent, (const char*)parent_data, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';
    {
      char* slash = strrchr(parent, '\\');
      char* fslash = strrchr(parent, '/');
      if (fslash > slash) slash = fslash;
      if (slash != NULL) slash[1] = '\0'; else parent[0] = '\0';
    }
  } else {
    parent[0] = '\0';
  }

  snprintf(path, sizeof(path), "%s%s", parent, filename);

  fp = fopen(path, "rb");
  if (fp == NULL) return E_FAIL;
  fseek(fp, 0, SEEK_END);
  size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (size <= 0) { fclose(fp); return E_FAIL; }

  {
    char* buffer = (char*)malloc((size_t)size);
    if (buffer == NULL) { fclose(fp); return E_OUTOFMEMORY; }
    if (fread(buffer, 1, (size_t)size, fp) != (size_t)size) {
      fclose(fp); free(buffer); return E_FAIL;
    }
    fclose(fp);
    *data = buffer;
    *bytes = (UINT)size;
  }
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE IncludeClose(ID3DInclude* this_ptr, LPCVOID data) {
  (void)this_ptr;
  free((void*)data);
  return S_OK;
}

static ID3DInclude include_handler = {
    IncludeQueryInterface, IncludeAddRef, IncludeRelease,
    IncludeOpen, IncludeClose
};

static unsigned char* read_file(const char* path, SIZE_T* size) {
  FILE* fp = fopen(path, "rb");
  if (fp == NULL) { fprintf(stderr, "Cannot open %s\n", path); return NULL; }
  fseek(fp, 0, SEEK_END);
  long length = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (length <= 0) { fclose(fp); fprintf(stderr, "Empty file %s\n", path); return NULL; }
  unsigned char* data = (unsigned char*)malloc((size_t)length + 1);
  if (data == NULL || fread(data, 1, (size_t)length, fp) != (size_t)length) {
    fclose(fp); free(data); fprintf(stderr, "Read failed %s\n", path); return NULL;
  }
  fclose(fp);
  data[length] = 0;
  *size = (SIZE_T)length;
  return data;
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s input.hlsl output.cso <target> [entry=main]\n", argv[0]);
    return 2;
  }
  const char* target = argv[3];
  const char* entry = (argc >= 5) ? argv[4] : "main";

  SIZE_T size = 0;
  unsigned char* source = read_file(argv[1], &size);
  if (source == NULL) return 1;

  HMODULE dll = LoadLibraryA("d3dcompiler_47.dll");
  if (dll == NULL) { fprintf(stderr, "Could not load d3dcompiler_47.dll\n"); free(source); return 1; }
  D3DCompileFn compile = (D3DCompileFn)GetProcAddress(dll, "D3DCompile");
  if (compile == NULL) { fprintf(stderr, "No D3DCompile export.\n"); free(source); return 1; }

  ID3DBlob* code = NULL;
  ID3DBlob* errors = NULL;
  HRESULT hr = compile(source, size, argv[1], NULL, &include_handler, entry, target,
                       D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
                       0, &code, &errors);

  if (errors != NULL) {
    const char* msg = (const char*)errors->lpVtbl->GetBufferPointer(errors);
    fflush(stdout);
    fputs(msg, stderr);
    errors->lpVtbl->Release(errors);
  }
  if (FAILED(hr) || code == NULL) {
    fprintf(stderr, "\n%s compilation failed (hr=0x%08lX)\n", target, (unsigned long)hr);
    free(source);
    return 1;
  }

  FILE* out = fopen(argv[2], "wb");
  if (out == NULL) {
    fprintf(stderr, "Cannot write %s\n", argv[2]);
    code->lpVtbl->Release(code);
    free(source);
    return 1;
  }
  SIZE_T code_size = code->lpVtbl->GetBufferSize(code);
  fwrite(code->lpVtbl->GetBufferPointer(code), 1, code_size, out);
  fclose(out);

  printf("OK %s -> %s (%lu bytes)\n", target, argv[2], (unsigned long)code_size);
  code->lpVtbl->Release(code);
  free(source);
  return 0;
}