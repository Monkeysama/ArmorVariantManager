namespace { int hosted = 1; }
extern "C" __declspec(dllexport) int avm_ui_portrait_hosted() { return hosted; }
extern "C" __declspec(dllexport) void test_set_hosted(int value) { hosted = value; }
