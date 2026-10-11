package com.lagradost.macos

import com.googlecode.d2j.DexLabel
import com.googlecode.d2j.Field
import com.googlecode.d2j.Method
import com.googlecode.d2j.reader.BaseDexFileReader
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.d2j.reader.Op
import com.googlecode.d2j.visitors.DexClassVisitor
import com.googlecode.d2j.visitors.DexCodeVisitor
import com.googlecode.d2j.visitors.DexFileVisitor
import com.googlecode.d2j.visitors.DexMethodVisitor

/**
 * Bounds DEX → JVM translation per method. dex2jar's register analysis grows
 * far faster than linearly with a method's size × registers; one huge method
 * (StreamPlay's 43k-instruction, 157-register `invokeMovieBox`) exhausted 4 GB
 * while the whole worker has 256 MB. Such methods are translated as a body that
 * throws a named [UnsupportedOperationException]: the extension loads, only
 * the paths through that method fail, and the limitation is reported. This
 * also stops a crafted DEX from exhausting a worker during translation.
 */
internal object TranslationGuard {
    /** Statements × registers above which a method is not translated. */
    const val MAX_COMPLEXITY = 2_000_000L
    /** Statements above which a method is not translated, whatever its registers. */
    const val MAX_STATEMENTS = 30_000

    data class Oversized(val owner: String, val name: String, val descriptor: String, val statements: Int, val registers: Int) {
        /** `Owner.method`, for users. */
        val label: String get() = owner.removePrefix("L").removeSuffix(";").substringAfterLast('/') + "." + name
    }

    /** Methods of [dex] that would not be translated. Reads the file once without translating. */
    fun scan(dex: ByteArray, maxComplexity: Long = MAX_COMPLEXITY, maxStatements: Int = MAX_STATEMENTS): List<Oversized> {
        fun tooComplex(statements: Int, registers: Int) =
            statements > maxStatements || statements.toLong() * registers.coerceAtLeast(1) > maxComplexity
        val found = mutableListOf<Oversized>()
        MultiDexFileReader.open(dex).accept(object : DexFileVisitor() {
            override fun visit(access: Int, className: String, superClass: String?, interfaceNames: Array<out String>?) = object : DexClassVisitor() {
                override fun visitMethod(accessFlags: Int, method: Method) = object : DexMethodVisitor() {
                    override fun visitCode(): DexCodeVisitor = Counter { statements, registers ->
                        if (tooComplex(statements, registers)) found += Oversized(className, method.name, method.desc, statements, registers)
                    }
                }
            }
        }, SKIP)
        return found
    }

    /** A reader that hands dex2jar a throwing body in place of each method in [oversized]. */
    fun guard(dex: ByteArray, oversized: List<Oversized>): BaseDexFileReader {
        val reader = MultiDexFileReader.open(dex)
        if (oversized.isEmpty()) return reader
        val keys = oversized.map { Triple(it.owner, it.name, it.descriptor) }.toSet()
        return object : BaseDexFileReader by reader {
            override fun accept(dv: DexFileVisitor) = accept(dv, 0)
            override fun accept(dv: DexFileVisitor, config: Int) = reader.accept(stubbing(dv, keys), config)
            override fun accept(dv: DexFileVisitor, classIdx: Int, config: Int) = reader.accept(stubbing(dv, keys), classIdx, config)
        }
    }

    private fun stubbing(target: DexFileVisitor, keys: Set<Triple<String, String, String>>) = object : DexFileVisitor(target) {
        override fun visit(access: Int, className: String, superClass: String?, interfaceNames: Array<out String>?): DexClassVisitor? {
            val classVisitor = super.visit(access, className, superClass, interfaceNames) ?: return null
            return object : DexClassVisitor(classVisitor) {
                override fun visitMethod(accessFlags: Int, method: Method): DexMethodVisitor? {
                    val methodVisitor = super.visitMethod(accessFlags, method) ?: return null
                    if (Triple(className, method.name, method.desc) !in keys) return methodVisitor
                    val static = accessFlags and ACC_STATIC != 0
                    return object : DexMethodVisitor(methodVisitor) {
                        override fun visitCode(): DexCodeVisitor? {
                            val code = super.visitCode() ?: return null
                            // Swallow the original body; emit the stub when it ends.
                            return object : DexCodeVisitor() {
                                override fun visitEnd() = emitStub(code, method, static)
                            }
                        }
                    }
                }
            }
        }
    }

    /** `throw new UnsupportedOperationException(message)` with the method's parameters in the top registers. */
    private fun emitStub(code: DexCodeVisitor, method: Method, static: Boolean) {
        val parameterWords = method.parameterTypes.sumOf { if (it == "J" || it == "D") 2 else 1 } + if (static) 0 else 1
        code.visitRegister(2 + parameterWords)
        code.visitTypeStmt(Op.NEW_INSTANCE, 0, 0, EXCEPTION)
        code.visitConstStmt(Op.CONST_STRING, 1, "${method.owner.removePrefix("L").removeSuffix(";").replace('/', '.')}.${method.name} " +
            "is too large to translate for macOS and cannot run.")
        code.visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(0, 1), Method(EXCEPTION, "<init>", arrayOf("Ljava/lang/String;"), "V"))
        code.visitStmt1R(Op.THROW, 0)
        code.visitEnd()
    }

    /** Counts statements and records the register count of one method body. */
    private class Counter(private val done: (statements: Int, registers: Int) -> Unit) : DexCodeVisitor() {
        private var statements = 0
        private var registers = 0
        override fun visitRegister(total: Int) { registers = total }
        override fun visitStmt2R1N(op: Op?, distReg: Int, srcReg: Int, content: Int) { statements++ }
        override fun visitStmt3R(op: Op?, a: Int, b: Int, c: Int) { statements++ }
        override fun visitTypeStmt(op: Op?, a: Int, b: Int, type: String?) { statements++ }
        override fun visitConstStmt(op: Op?, ra: Int, value: Any?) { statements++ }
        override fun visitFillArrayDataStmt(op: Op?, ra: Int, array: Any?) { statements++ }
        override fun visitFieldStmt(op: Op?, a: Int, b: Int, field: Field?) { statements++ }
        override fun visitFilledNewArrayStmt(op: Op?, args: IntArray?, type: String?) { statements++ }
        override fun visitJumpStmt(op: Op?, a: Int, b: Int, label: DexLabel?) { statements++ }
        override fun visitSparseSwitchStmt(op: Op?, ra: Int, cases: IntArray?, labels: Array<out DexLabel>?) { statements++ }
        override fun visitMethodStmt(op: Op?, args: IntArray?, method: Method?) { statements++ }
        override fun visitMethodStmt(op: Op?, args: IntArray?, call: com.googlecode.d2j.CallSite?) { statements++ }
        override fun visitMethodStmt(op: Op?, args: IntArray?, method: Method?, proto: com.googlecode.d2j.Proto?) { statements++ }
        override fun visitStmt2R(op: Op?, a: Int, b: Int) { statements++ }
        override fun visitStmt0R(op: Op?) { statements++ }
        override fun visitStmt1R(op: Op?, reg: Int) { statements++ }
        override fun visitPackedSwitchStmt(op: Op?, aA: Int, firstCase: Int, labels: Array<out DexLabel>?) { statements++ }
        override fun visitEnd() = done(statements, registers)
    }

    private const val EXCEPTION = "Ljava/lang/UnsupportedOperationException;"
    private const val ACC_STATIC = 0x0008
    /** The scan needs only code. */
    private const val SKIP = com.googlecode.d2j.reader.DexFileReader.SKIP_DEBUG or com.googlecode.d2j.reader.DexFileReader.SKIP_ANNOTATION
}
