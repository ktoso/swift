////// first entry -----------------------------------------------------------------------------------------------------
* thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
  frame #0: 0x00000001042804cc swift-frontend`swift::NormalProtocolConformance::setWitness(this=0x00000001484d0998, requirement=0x000000012d4be458, witness=Witness @ 0x000000016fdf3cc0) const at ProtocolConformance.cpp:692:13
  frame #1: 0x0000000103227cdc swift-frontend`swift::ConformanceChecker::recordWitness(this=0x000000016fdf4860, requirement=0x000000012d4be458, match=0x000000016fdf4460) at TypeCheckProtocol.cpp:3010:16
* frame #2: 0x000000010322b444 swift-frontend`swift::ConformanceChecker::resolveWitnessViaLookup(this=0x000000016fdf4860, requirement=0x000000012d4be458) at TypeCheckProtocol.cpp:4358:5
  frame #3: 0x000000010322c168 swift-frontend`swift::ConformanceChecker::resolveWitnessTryingAllStrategies(this=0x000000016fdf4860, requirement=0x000000012d4be458) at TypeCheckProtocol.cpp:4567:35
  frame #4: 0x000000010322c67c swift-frontend`swift::ConformanceChecker::resolveValueWitnesses(this=0x000000016fdf4860) at TypeCheckProtocol.cpp:5107:13
  frame #5: 0x000000010322d840 swift-frontend`swift::ResolveValueWitnessesRequest::evaluate(this=0x000000016fdf4b28, evaluator=0x000000013f8c3a78, conformance=0x00000001484d0998) const at TypeCheckProtocol.cpp:5147:11
  frame #6: 0x000000010329bce8 swift-frontend`std::__1::tuple<> swift::SimpleRequest<swift::ResolveValueWitnessesRequest, std::__1::tuple<> (swift::NormalProtocolConformance*), (swift::RequestFlags)2>::callDerived<0ul>(this=0x000000016fdf4b28, evaluator=0x000000013f8c3a78, (null)=std::__1::index_sequence<0UL> @ 0x000000016fdf491f) const at SimpleRequest.h:272:24
  frame #7: 0x0000000103295788 swift-frontend`swift::SimpleRequest<swift::ResolveValueWitnessesRequest, std::__1::tuple<> (swift::NormalProtocolConformance*), (swift::RequestFlags)2>::evaluateRequest(request=0x000000016fdf4b28, evaluator=0x000000013f8c3a78) at SimpleRequest.h:295:20
  frame #8: 0x000000010429d484 swift-frontend`swift::ResolveValueWitnessesRequest::OutputType swift::Evaluator::getResultUncached<swift::ResolveValueWitnessesRequest, swift::ResolveValueWitnessesRequest::OutputType swift::evaluateOrDefault<swift::ResolveValueWitnessesRequest>(swift::Evaluator&, swift::ResolveValueWitnessesRequest, swift::ResolveValueWitnessesRequest::OutputType)::'lambda'()>(this=0x000000013f8c3a78, request=0x000000016fdf4b28, defaultValueFn=(unnamed class) @ 0x000000016fdf4a06) at Evaluator.h:322:19
  frame #9: 0x000000010429d384 swift-frontend`swift::ResolveValueWitnessesRequest::OutputType swift::Evaluator::getResultCached<swift::ResolveValueWitnessesRequest, swift::ResolveValueWitnessesRequest::OutputType swift::evaluateOrDefault<swift::ResolveValueWitnessesRequest>(swift::Evaluator&, swift::ResolveValueWitnessesRequest, swift::ResolveValueWitnessesRequest::OutputType)::'lambda'(), (void*)0>(this=0x000000013f8c3a78, request=0x000000016fdf4b28, defaultValueFn=(unnamed class) @ 0x000000016fdf4abe) at Evaluator.h:377:19
  frame #10: 0x000000010429d294 swift-frontend`swift::ResolveValueWitnessesRequest::OutputType swift::Evaluator::operator()<swift::ResolveValueWitnessesRequest, swift::ResolveValueWitnessesRequest::OutputType swift::evaluateOrDefault<swift::ResolveValueWitnessesRequest>(swift::Evaluator&, swift::ResolveValueWitnessesRequest, swift::ResolveValueWitnessesRequest::OutputType)::'lambda'(), (void*)0>(this=0x000000013f8c3a78, request=0x000000016fdf4b28, defaultValueFn=(unnamed class) @ 0x000000016fdf4aff) at Evaluator.h:226:14
  frame #11: 0x0000000104280924 swift-frontend`swift::ResolveValueWitnessesRequest::OutputType swift::evaluateOrDefault<swift::ResolveValueWitnessesRequest>(eval=0x000000013f8c3a78, req=ResolveValueWitnessesRequest @ 0x000000016fdf4b28, def=size=0) at Evaluator.h:416:10
  frame #12: 0x00000001042808ec swift-frontend`swift::NormalProtocolConformance::resolveValueWitnesses(this=0x00000001484d0998) const at ProtocolConformance.cpp:724:3
  frame #13: 0x00000001015acbac swift-frontend`(anonymous namespace)::SILGenConformance::emit(this=0x000000016fdf4cc8) at SILGenType.cpp:557:18
  frame #14: 0x00000001015ac86c swift-frontend`swift::Lowering::SILGenModule::getWitnessTable(this=0x000000016fdf4fa0, conformance=0x00000001484d0998) at SILGenType.cpp:717:66
  frame #15: 0x000000010136abb8 swift-frontend`(anonymous namespace)::SILGenModuleRAII::~SILGenModuleRAII(this=0x000000016fdf4fa0) at SILGen.cpp:2130:19
  frame #16: 0x0000000101363e3c swift-frontend`(anonymous namespace)::SILGenModuleRAII::~SILGenModuleRAII(this=0x000000016fdf4fa0) at SILGen.cpp:2117:23
  frame #17: 0x0000000101363634 swift-frontend`swift::ASTLoweringRequest::evaluate(this=0x000000016fdf5710, evaluator=0x000000013f8c3a78, desc=ASTLoweringDescriptor @ 0x000000016fdf54b0) const at SILGen.cpp:2185:1
  frame #18: 0x00000001015895d0 swift-frontend`std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule>> swift::SimpleRequest<swift::ASTLoweringRequest, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule>> (swift::ASTLoweringDescriptor), (swift::RequestFlags)9>::callDerived<0ul>(this=0x000000016fdf5710, evaluator=0x000000013f8c3a78, (null)=std::__1::index_sequence<0UL> @ 0x000000016fdf54a7) const at SimpleRequest.h:272:24
  frame #19: 0x000000010158951c swift-frontend`swift::SimpleRequest<swift::ASTLoweringRequest, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule>> (swift::ASTLoweringDescriptor), (swift::RequestFlags)9>::evaluateRequest(request=0x000000016fdf5710, evaluator=0x000000013f8c3a78) at SimpleRequest.h:295:20
  frame #20: 0x0000000101380ff8 swift-frontend`swift::ASTLoweringRequest::OutputType swift::Evaluator::getResultUncached<swift::ASTLoweringRequest, swift::ASTLoweringRequest::OutputType swift::evaluateOrFatal<swift::ASTLoweringRequest>(swift::Evaluator&, swift::ASTLoweringRequest)::'lambda'()>(this=0x000000013f8c3a78, request=0x000000016fdf5710, defaultValueFn=(unnamed class) @ 0x000000016fdf55ff) at Evaluator.h:322:19
  frame #21: 0x0000000101380ef4 swift-frontend`swift::ASTLoweringRequest::OutputType swift::Evaluator::operator()<swift::ASTLoweringRequest, swift::ASTLoweringRequest::OutputType swift::evaluateOrFatal<swift::ASTLoweringRequest>(swift::Evaluator&, swift::ASTLoweringRequest)::'lambda'(), (void*)0>(this=0x000000013f8c3a78, request=0x000000016fdf5710, defaultValueFn=(unnamed class) @ 0x000000016fdf5657) at Evaluator.h:237:12
  frame #22: 0x0000000101363fe4 swift-frontend`swift::ASTLoweringRequest::OutputType swift::evaluateOrFatal<swift::ASTLoweringRequest>(eval=0x000000013f8c3a78, req=ASTLoweringRequest @ 0x000000016fdf5710) at Evaluator.h:423:10
  frame #23: 0x0000000101364274 swift-frontend`swift::performASTLowering(sf=0x000000012f084c00, tc=0x000000012ee973a0, options=0x000000016fdf5a38, irgenOptions=0x000000016fdf60e0) at SILGen.cpp:2216:10
  frame #24: 0x0000000100370760 swift-frontend`swift::performCompileStepsPostSema(Instance=0x0000000140029a00, ReturnValue=0x000000016fdf71ac, observer=0x0000000000000000) at FrontendTool.cpp:899:17
  frame #25: 0x00000001003a07a0 swift-frontend`performAction(swift::CompilerInstance&, int&, swift::FrontendObserver*)::$_29::operator()(this=0x000000016fdf6bd0, Instance=0x0000000140029a00) const at FrontendTool.cpp:1451:18
  frame #26: 0x00000001003a0704 swift-frontend`bool llvm::function_ref<bool (swift::CompilerInstance&)>::callback_fn<performAction(swift::CompilerInstance&, int&, swift::FrontendObserver*)::$_29>(callable=6171880400, params=0x0000000140029a00) at STLFunctionalExtras.h:45:12
  frame #27: 0x000000010039fab4 swift-frontend`llvm::function_ref<bool (swift::CompilerInstance&)>::operator()(this=0x000000016fdf6b08, params=0x0000000140029a00) const at STLFunctionalExtras.h:68:12
  frame #28: 0x000000010039e974 swift-frontend`withSemanticAnalysis(Instance=0x0000000140029a00, observer=0x0000000000000000, cont=function_ref<bool (swift::CompilerInstance &)> @ 0x000000016fdf6b08, runDespiteErrors=false) at FrontendTool.cpp:1311:10
  frame #29: 0x0000000100399590 swift-frontend`performAction(Instance=0x0000000140029a00, ReturnValue=0x000000016fdf71ac, observer=0x0000000000000000) at FrontendTool.cpp:1447:12
  frame #30: 0x0000000100373370 swift-frontend`performCompile(Instance=0x0000000140029a00, ReturnValue=0x000000016fdf71ac, observer=0x0000000000000000) at FrontendTool.cpp:1522:19
  frame #31: 0x0000000100372018 swift-frontend`swift::performFrontend(Args=ArrayRef<const char *> @ 0x000000016fdf73d8, Argv0="/Users/ktoso/code/swift-project/build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64/bin/swift-frontend", MainAddr=0x000000010004e3e0, observer=0x0000000000000000) at FrontendTool.cpp:2473:19
  frame #32: 0x000000010004f484 swift-frontend`run_driver(ExecName=(Data = "swift-frontend", Length = 14), argv=ArrayRef<const char *> @ 0x000000016fdf9850, originalArgv=const llvm::ArrayRef<const char *> @ 0x000000016fdf9840) at driver.cpp:256:14
  frame #33: 0x000000010004e898 swift-frontend`swift::mainEntry(argc_=196, argv_=0x000000016fdfc428) at driver.cpp:531:10
  frame #34: 0x000000010004e0b4 swift-frontend`main(argc_=196, argv_=0x000000016fdfc428) at driver.cpp:20:10
  frame #35: 0x00000001889890e0 dyld`start + 2360






















////// Second entry ----------------------------------------------------------------------------------------------------
* thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
* frame #0: 0x00000001042804cc swift-frontend`swift::NormalProtocolConformance::setWitness(this=0x00000001484d0998, requirement=0x000000012d4be458, witness=Witness @ 0x000000016fdf3860) const at ProtocolConformance.cpp:692:13
  frame #1: 0x000000010229546c swift-frontend`swift::ModuleFile::finishNormalConformance(swift::NormalProtocolConformance*, unsigned long long)::$_20::operator()(this=0x000000016fdf3b88, w=Witness @ 0x000000016fdf38a0) const at Deserialization.cpp:8497:22
  frame #2: 0x00000001022947ec swift-frontend`swift::ModuleFile::finishNormalConformance(this=0x000000012f0ca000, conformance=0x00000001484d0998, contextData=471769) at Deserialization.cpp:8574:5
  frame #3: 0x000000010427ee7c swift-frontend`swift::NormalProtocolConformance::resolveLazyInfo(this=0x00000001484d0998) const at ProtocolConformance.cpp:433:11
  frame #4: 0x000000010427d42c swift-frontend`swift::NormalProtocolConformance::getWitness(this=0x00000001484d0998, requirement=0x000000012d4be458) const at ProtocolConformance.cpp:637:5
  frame #5: 0x00000001015b331c swift-frontend`(anonymous namespace)::SILGenConformance::getWitness(this=0x000000016fdf4cc8, decl=0x000000012d4be458) at SILGenType.cpp:615:25
  frame #6: 0x00000001015b2c50 swift-frontend`(anonymous namespace)::SILGenWitnessTable<(anonymous namespace)::SILGenConformance>::addMethod(this=0x000000016fdf4cc8, requirementRef=SILDeclRef @ 0x000000016fdf46b0) at SILGenType.cpp:456:32
  frame #7: 0x00000001015b28e0 swift-frontend`swift::SILWitnessVisitor<(anonymous namespace)::SILGenConformance>::visitAbstractStorageDecl(this=0x000000016fdf4828, accessor=0x000000012d4be4c0)::'lambda'(swift::AccessorDecl*)::operator()(swift::AccessorDecl*) const at SILWitnessVisitor.h:129:21
  frame #8: 0x00000001015b2814 swift-frontend`void llvm::function_ref<void (swift::AccessorDecl*)>::callback_fn<swift::SILWitnessVisitor<(anonymous namespace)::SILGenConformance>::visitAbstractStorageDecl(swift::AbstractStorageDecl*)::'lambda'(swift::AccessorDecl*)>(callable=6171871272, params=0x000000012d4be4c0) at STLFunctionalExtras.h:45:12
  frame #9: 0x0000000101380358 swift-frontend`llvm::function_ref<void (swift::AccessorDecl*)>::operator()(this=0x000000016fdf4800, params=0x000000012d4be4c0) const at STLFunctionalExtras.h:68:12
  frame #10: 0x0000000103cf1300 swift-frontend`swift::AbstractStorageDecl::visitOpaqueAccessors(llvm::function_ref<void (swift::AccessorDecl*)>) const::$_9::operator()(this=0x000000016fdf47d8, kind=Get) const at Decl.cpp:3001:5
  frame #11: 0x0000000103cf1264 swift-frontend`void llvm::function_ref<void (swift::AccessorKind)>::callback_fn<swift::AbstractStorageDecl::visitOpaqueAccessors(llvm::function_ref<void (swift::AccessorDecl*)>) const::$_9>(callable=6171871192, params=Get) at STLFunctionalExtras.h:45:12
  frame #12: 0x0000000103c3d308 swift-frontend`llvm::function_ref<void (swift::AccessorKind)>::operator()(this=0x000000016fdf47b0, params=Get) const at STLFunctionalExtras.h:68:12
  frame #13: 0x0000000103c3d270 swift-frontend`swift::AbstractStorageDecl::visitExpectedOpaqueAccessors(this=0x000000012d4be458, visit=function_ref<void (swift::AccessorKind)> @ 0x000000016fdf47b0) const at Decl.cpp:2981:5
  frame #14: 0x0000000103c3cf2c swift-frontend`swift::AbstractStorageDecl::visitOpaqueAccessors(this=0x000000012d4be458, visit=function_ref<void (swift::AccessorDecl *)> @ 0x000000016fdf4800) const at Decl.cpp:2997:3
  frame #15: 0x00000001015b2770 swift-frontend`swift::SILWitnessVisitor<(anonymous namespace)::SILGenConformance>::visitAbstractStorageDecl(this=0x000000016fdf4cc8, sd=0x000000012d4be458) at SILWitnessVisitor.h:127:9
  frame #16: 0x00000001015b1f94 swift-frontend`swift::ASTVisitor<(anonymous namespace)::SILGenConformance, void, void, void, void, void, void>::visitVarDecl(this=0x000000016fdf4cc8, D=0x000000012d4be458) at DeclNodes.def:171:5
  frame #17: 0x00000001015b0274 swift-frontend`swift::ASTVisitor<(anonymous namespace)::SILGenConformance, void, void, void, void, void, void>::visit(this=0x000000016fdf4cc8, D=0x000000012d4be458) at DeclNodes.def:171:5
  frame #18: 0x00000001015afb20 swift-frontend`swift::SILWitnessVisitor<(anonymous namespace)::SILGenConformance>::visitProtocolDecl(this=0x000000016fdf4cc8, protocol=0x0000000129a5c500) at SILWitnessVisitor.h:111:22
  frame #19: 0x00000001015acbcc swift-frontend`(anonymous namespace)::SILGenConformance::emit(this=0x000000016fdf4cc8) at SILGenType.cpp:559:5
  frame #20: 0x00000001015ac86c swift-frontend`swift::Lowering::SILGenModule::getWitnessTable(this=0x000000016fdf4fa0, conformance=0x00000001484d0998) at SILGenType.cpp:717:66
  frame #21: 0x000000010136abb8 swift-frontend`(anonymous namespace)::SILGenModuleRAII::~SILGenModuleRAII(this=0x000000016fdf4fa0) at SILGen.cpp:2130:19
  frame #22: 0x0000000101363e3c swift-frontend`(anonymous namespace)::SILGenModuleRAII::~SILGenModuleRAII(this=0x000000016fdf4fa0) at SILGen.cpp:2117:23
  frame #23: 0x0000000101363634 swift-frontend`swift::ASTLoweringRequest::evaluate(this=0x000000016fdf5710, evaluator=0x000000013f8c3a78, desc=ASTLoweringDescriptor @ 0x000000016fdf54b0) const at SILGen.cpp:2185:1
  frame #24: 0x00000001015895d0 swift-frontend`std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule>> swift::SimpleRequest<swift::ASTLoweringRequest, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule>> (swift::ASTLoweringDescriptor), (swift::RequestFlags)9>::callDerived<0ul>(this=0x000000016fdf5710, evaluator=0x000000013f8c3a78, (null)=std::__1::index_sequence<0UL> @ 0x000000016fdf54a7) const at SimpleRequest.h:272:24
  frame #25: 0x000000010158951c swift-frontend`swift::SimpleRequest<swift::ASTLoweringRequest, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule>> (swift::ASTLoweringDescriptor), (swift::RequestFlags)9>::evaluateRequest(request=0x000000016fdf5710, evaluator=0x000000013f8c3a78) at SimpleRequest.h:295:20
  frame #26: 0x0000000101380ff8 swift-frontend`swift::ASTLoweringRequest::OutputType swift::Evaluator::getResultUncached<swift::ASTLoweringRequest, swift::ASTLoweringRequest::OutputType swift::evaluateOrFatal<swift::ASTLoweringRequest>(swift::Evaluator&, swift::ASTLoweringRequest)::'lambda'()>(this=0x000000013f8c3a78, request=0x000000016fdf5710, defaultValueFn=(unnamed class) @ 0x000000016fdf55ff) at Evaluator.h:322:19
  frame #27: 0x0000000101380ef4 swift-frontend`swift::ASTLoweringRequest::OutputType swift::Evaluator::operator()<swift::ASTLoweringRequest, swift::ASTLoweringRequest::OutputType swift::evaluateOrFatal<swift::ASTLoweringRequest>(swift::Evaluator&, swift::ASTLoweringRequest)::'lambda'(), (void*)0>(this=0x000000013f8c3a78, request=0x000000016fdf5710, defaultValueFn=(unnamed class) @ 0x000000016fdf5657) at Evaluator.h:237:12
  frame #28: 0x0000000101363fe4 swift-frontend`swift::ASTLoweringRequest::OutputType swift::evaluateOrFatal<swift::ASTLoweringRequest>(eval=0x000000013f8c3a78, req=ASTLoweringRequest @ 0x000000016fdf5710) at Evaluator.h:423:10
  frame #29: 0x0000000101364274 swift-frontend`swift::performASTLowering(sf=0x000000012f086250, tc=0x000000012ee973a0, options=0x000000016fdf5a38, irgenOptions=0x000000016fdf60e0) at SILGen.cpp:2216:10
  frame #30: 0x0000000100370760 swift-frontend`swift::performCompileStepsPostSema(Instance=0x0000000140029a00, ReturnValue=0x000000016fdf71ac, observer=0x0000000000000000) at FrontendTool.cpp:899:17
  frame #31: 0x00000001003a07a0 swift-frontend`performAction(swift::CompilerInstance&, int&, swift::FrontendObserver*)::$_29::operator()(this=0x000000016fdf6bd0, Instance=0x0000000140029a00) const at FrontendTool.cpp:1451:18
  frame #32: 0x00000001003a0704 swift-frontend`bool llvm::function_ref<bool (swift::CompilerInstance&)>::callback_fn<performAction(swift::CompilerInstance&, int&, swift::FrontendObserver*)::$_29>(callable=6171880400, params=0x0000000140029a00) at STLFunctionalExtras.h:45:12
  frame #33: 0x000000010039fab4 swift-frontend`llvm::function_ref<bool (swift::CompilerInstance&)>::operator()(this=0x000000016fdf6b08, params=0x0000000140029a00) const at STLFunctionalExtras.h:68:12
  frame #34: 0x000000010039e974 swift-frontend`withSemanticAnalysis(Instance=0x0000000140029a00, observer=0x0000000000000000, cont=function_ref<bool (swift::CompilerInstance &)> @ 0x000000016fdf6b08, runDespiteErrors=false) at FrontendTool.cpp:1311:10
  frame #35: 0x0000000100399590 swift-frontend`performAction(Instance=0x0000000140029a00, ReturnValue=0x000000016fdf71ac, observer=0x0000000000000000) at FrontendTool.cpp:1447:12
  frame #36: 0x0000000100373370 swift-frontend`performCompile(Instance=0x0000000140029a00, ReturnValue=0x000000016fdf71ac, observer=0x0000000000000000) at FrontendTool.cpp:1522:19
  frame #37: 0x0000000100372018 swift-frontend`swift::performFrontend(Args=ArrayRef<const char *> @ 0x000000016fdf73d8, Argv0="/Users/ktoso/code/swift-project/build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64/bin/swift-frontend", MainAddr=0x000000010004e3e0, observer=0x0000000000000000) at FrontendTool.cpp:2473:19
  frame #38: 0x000000010004f484 swift-frontend`run_driver(ExecName=(Data = "swift-frontend", Length = 14), argv=ArrayRef<const char *> @ 0x000000016fdf9850, originalArgv=const llvm::ArrayRef<const char *> @ 0x000000016fdf9840) at driver.cpp:256:14
  frame #39: 0x000000010004e898 swift-frontend`swift::mainEntry(argc_=196, argv_=0x000000016fdfc428) at driver.cpp:531:10
  frame #40: 0x000000010004e0b4 swift-frontend`main(argc_=196, argv_=0x000000016fdfc428) at driver.cpp:20:10
  frame #41: 0x00000001889890e0 dyld`start + 2360




(lldb) e conformance->dump()
(normal_conformance type="Self" protocol="Actor"
(value req="unownedExecutor" witness="Distributed.(file).DistributedActor extension.__actorUnownedExecutor")
(assoc_conformance type="Self" proto="AnyActor"
(abstract_conformance protocol="AnyActor")))


