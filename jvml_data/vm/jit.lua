local function compile(class, method, codeAttr, cp)
    local function resolveClass(c)
        local cn = cp[c.name_index].bytes:gsub("/",".")
        return classByName(cn)
    end

    local lineNumberAttribute
    local stackMapAttribute
    for i=0,codeAttr.attributes_count-1 do
        if codeAttr.attributes[i].name == "LineNumberTable" then
            lineNumberAttribute = codeAttr.attributes[i]
        elseif codeAttr.attributes[i].name == "StackMapTable" then
            stackMapAttribute = codeAttr.attributes[i]
        end
    end

    local sourceFileName
    for i=0,class.attributes_count-1 do
        if class.attributes[i].name == "SourceFile" then
            sourceFileName = cp[class.attributes[i].source_file_index].bytes
        end
    end

    local code = codeAttr.code
    local asm = { }

    local comments = { }
    local asmPC = 1
    local function emitWithComment(comment, str, ...)
        if comment then
            comments[asmPC] = "\t\t\t; " .. comment
        end
        local _, err = pcall(function(...)
            asmPC = asmPC + 1
            asm[#asm + 1] = string.format(str, ...) .. "\n"
        end, ...)
        if err then
            error(err, 2)
        end
    end

    local function emit(str, ...)
        emitWithComment(nil, str, ...)
    end

    local function emitInsert(pc, str, ...)
        local _, err = pcall(function(...)
            asm[pc] = string.format(str, ...) .. "\n"
        end, ...)
        if err then
            error(err, 2)
        end
    end

    local reg = codeAttr.max_locals
    local function alloc(n)
        if not n then n = 1 end
        local ret = { }
        for i = 1, n do
            reg = reg + 1
            ret[i] = reg
        end
        return unpack(ret)
    end

    local function free(n)
        if not n then n = 1 end
        local ret = { }
        for i = n, 1, -1 do
            ret[i] = reg
            reg = reg - 1
        end
        return unpack(ret)
    end

    -- freeTo IS NOW DECEPTIVELY NAMED
    -- It is also capable of allocating memory if n > current stack!
    local function freeTo(n)
        n = (n or 0) + codeAttr.max_locals
        if n <= reg then
            return free(reg - n)
        else
            return alloc(n - reg)
        end
    end

    local function peek(n)
        return reg - n
    end

    local rti = { }
    local reverseRTI = { }
    local function info(obj)
        local i = reverseRTI[obj]
        if i then
            return i
        end
        local p = #rti + 1
        rti[p] = obj
        reverseRTI[obj] = p
        return p
    end

    local _pc = 0
    local function u1()
        _pc = _pc+1
        return code[_pc-1]
    end
    local function pc(i)
        _pc = i or _pc
        return _pc - 1
    end

    local pcMapLJ = { }
    local pcMapJL = { }

    local function u2()
        return bit.blshift(u1(),8) + u1()
    end

    local function u4()
        return bit.blshift(u1(),24) + bit.blshift(u1(),16) + bit.blshift(u1(),8) + u1()
    end

    local function s4()
        local u = u4()
        if u < 2147483648 then
            return u
        end
        return u - 4294967296
    end

    local function asmGetRTInfo(r, i)
        emit("gettable %i 0 k(%i) ", r, i)
    end

    local function asmNewInstance(robj, class, customObjectSize)
        local rclass, rfields, rmethods = alloc(3)
        asmGetRTInfo(rclass, info(class))
        asmGetRTInfo(rmethods, info(class.methods))
        emit("newtable %i %i 0", robj, customObjectSize or 3)
        emit("newtable %i %i 0", rfields, #class.fields)
        emit("settable %i k(1) %i", robj, rclass)
        emit("settable %i k(2) %i", robj, rfields)
        emit("settable %i k(3) %i", robj, rmethods)
        free(3)
    end

    local function asmNewArray(robj, rlength, class)
        local rarray = alloc()
        emit("newtable %i 0 0", rarray)
        asmNewInstance(robj, class, 5)
        emit("settable %i k(4) %i", robj, rlength)
        emit("settable %i k(5) %i", robj, rarray)
        free()
    end

    local function asmNewPrimitiveArray(robj, rlength, class)
        local rarray, ri = alloc(2)

        emit("newtable %i 0 0", rarray)
        emit("loadk %i k(1)", ri)
        emit("le 0 %i %i", ri, rlength)
        emit("jmp 3")
        emit("settable %i %i k(0)", rarray, ri) -- all primitives are represented by integers and default to 0
        emit("add %i %i k(1)", ri, ri)
        emit("jmp -5")

        asmNewInstance(robj, class, 5)
        emit("settable %i k(4) %i", robj, rlength)
        emit("settable %i k(5) %i", robj, rarray)
        free(2)
    end

    local function asmPrintReg(r)
        local rprint, rparam = alloc(2)
        emit("getglobal %i 'print'", rprint)
        emit("move %i %i", rparam, r)
        emit("call %i 2 1", rprint)
        free(2)
    end

    local function asmPrintString(str)
        local rprint, rparam = alloc(2)
        emit("getglobal %i 'print'", rprint)
        emit("loadk %i '%s'", rparam, str)
        emit("call %i 2 1", rprint)
        free(2)
    end

    -- Expects method at register rmt followed by args.
    -- Result is stored in rmt + 1.
    local function asmInvokeMethod(rmt, argslen, results)
        emit("gettable %i %i k(1)", rmt, rmt)
        emit("call %i %i %i", rmt, argslen + 1, results + 1)
    end

    local function asmRun(func)
        local rfunc = alloc()
        asmGetRTInfo(rfunc, info(func))
        emit("call %i %i %i", rfunc, 1, 1)
        free()
    end

    local function asmPushStackTrace()
        local rpush, rClassName, rMethodName, rFileName, rLineNumber = alloc(5)
        asmGetRTInfo(rpush, info(pushStackTrace))
        asmGetRTInfo(rClassName, info(class.name))
        asmGetRTInfo(rMethodName, info(method.name:sub(1, method.name:find("%(") - 1)))
        asmGetRTInfo(rFileName, info(sourceFileName or ""))
        asmGetRTInfo(rLineNumber, info(0))
        emit("call %i 5 1", rpush)
        free(5)
    end

    local function asmPopStackTrace()
        local rpop = alloc()
        asmGetRTInfo(rpop, info(popStackTrace))
        emit("call %i 1 1", rpop)
        free()
    end

    local function asmSetStackTraceLineNumber(ln)
        local rset, rln = alloc(2)
        asmGetRTInfo(rset, info(setStackTraceLineNumber))
        asmGetRTInfo(rln, info(ln))
        emit("call %i 2 1", rset)
        free(2)
    end

    local function asmInstanceOf(c)
        local r = peek(0)
        local robj, rclass = alloc(2)
        emit("move %i %i", robj, r)
        asmGetRTInfo(rclass, info(c))
        asmGetRTInfo(r, info(jInstanceof))
        emit("call %i 3 2", r)
        free(2)
    end

    local function asmThrow(rexception)
        local exceptionHandlers = {}
        for i=0, codeAttr.exception_table_length-1 do
            local handler = codeAttr.exception_table[i]
            if handler.start_pc <= pc() and handler.end_pc > pc() then
                table.insert(exceptionHandlers, handler)
            end
        end
        for i=1, #exceptionHandlers do
            local handler = exceptionHandlers[i]
            if handler.catch_type == 0 then
                emit("#jmp (%i)", handler.handler_pc)
            else
                local c = resolveClass(cp[handler.catch_type])
                local rtest = alloc()
                emit("move %i %i", rtest, rexception)
                asmInstanceOf(c)
                emit("test %i 0", rtest)
                emit("jmp 2")
                emit("move %i %i", codeAttr.max_locals + 1, rexception)
                emit("#jmp (%i)", handler.handler_pc)
                free()
            end
        end
        asmPopStackTrace()
        local rnil, rexc = alloc(2)
        emit("loadnil %i %i", rnil, rnil)
        emit("move %i %i", rexc, rexception)
        emit("return %i 3", rnil)
        free(2)
    end

    local function asmCheckThrow(rexception)
        emit("test %i 0", rexception)
        -- It's expected that no more reading is done after calling asmCheckThrow
        -- TODO: Come up with a better solution tahn expecting that
        emit("#jmp (%i)", pc() + 1)

        asmThrow(rexception)
    end

    local function getCurrentLineNumber()
        local ln
        if lineNumberAttribute then
            local len = lineNumberAttribute.line_number_table_length
            for i = 0, len - 1 do
                local entry = lineNumberAttribute.line_number_table[i]
                if entry.start_pc > pc() then
                    ln = lineNumberAttribute.line_number_table[i - 1].line_number
                    break
                end
            end
        end
        return ln
    end

    local function asmRefillStackTrace(rexception)
        asmSetStackTraceLineNumber(getCurrentLineNumber() or 0)

        local rfill, rexc = alloc(2)

        local fillInStackTrace = findMethod(classByName("java.lang.Throwable"), "fillInStackTrace()Ljava/lang/Throwable;")

        asmGetRTInfo(rfill, info(fillInStackTrace[1]))
        emit("move %i %i", rexc, rexception)
        emit("call %i 2 1", rfill)

        free(2)
    end

    local inst

    local oplookup = {
        function()      -- 01
            --null
            local r = alloc()
            emit("loadnil %i %i", r, r)
        end, function() -- 02
            local r = alloc()
            emit("loadk %i k(-1)", r)
        end, function() -- 03
            local r = alloc()
            emit("loadk %i k(0)", r)
        end, function() -- 04
            local r = alloc()
            emit("loadk %i k(1)", r)
        end, function() -- 05
            local r = alloc()
            emit("loadk %i k(2)", r)
        end, function() -- 06
            local r = alloc()
            emit("loadk %i k(3)", r)
        end, function() -- 07
            local r = alloc()
            emit("loadk %i k(4)", r)
        end, function() -- 08
            local r = alloc()
            emit("loadk %i k(5)", r)
        end, function() -- 09
            local r = alloc()
            emit("newtable %i 2 0", r)          -- r = { nil, nil }
            emit("settable %i k(1) k(0)", r)    -- r[1] = 0
            emit("settable %i k(2) k(0)", r)    -- r[2] = 0
        end, function() -- 0A
            local r = alloc()
            emit("newtable %i 2 0", r)          -- r = { nil, nil }
            emit("settable %i k(1) k(0)", r)    -- r[1] = 0
            emit("settable %i k(2) k(1)", r)    -- r[2] = 1
        end, function() -- 0B
            local r = alloc()
            emit("loadk %i k(0)", r)
        end, function() -- 0C
            local r = alloc()
            emit("loadk %i k(1)", r)
        end, function() -- 0D
            local r = alloc()
            emit("loadk %i k(2)", r)
        end, function() -- 0E
            local r = alloc()
            emit("loadk %i k(0)", r)
        end, function() -- 0F
            local r = alloc()
            emit("loadk %i k(1)", r)
        end, function() -- 10
            --push imm byte
            emit("loadk %i k(%i)", alloc(), u1())
        end, function() -- 11
            --push imm short
            emit("loadk %i k(%i)", alloc(), u2())
        end, function() -- 12
            local s = cp[u1()]
            if s.bytes then
                emit("loadk %i k(%s)", alloc(), s.bytes)
            elseif s.tag == CONSTANT.Class then
                local r = alloc()
                asmGetRTInfo(r, info(getJClass(cp[s.name_index].bytes:gsub("/", "."))))
            else
                local rtoJString, rStr = alloc(2)
                asmGetRTInfo(rtoJString, info(toJString))
                asmGetRTInfo(rStr, info(cp[s.string_index].bytes))
                emit("call %i 2 2", rtoJString)
                free()
            end
        end, function() -- 13
            --ldc_w
            --push constant
            local s = cp[u2()]
            if s.bytes then
                emit("loadk %i k(%s)", alloc(), s.bytes)
            elseif s.tag == CONSTANT.Class then
                local r = alloc()
                asmGetRTInfo(r, info(getJClass(cp[s.name_index].bytes:gsub("/", "."))))
            else
                local rtoJString, rStr = alloc(2)
                asmGetRTInfo(rtoJString, info(toJString))
                asmGetRTInfo(rStr, info(cp[s.string_index].bytes))
                emit("call %i 2 2", rtoJString)
                free()
            end
        end, function() -- 14
            --ldc2_w
            --push constant
            local s = cp[u2()]
            if s.cl == "D" then
                emit("loadk %i k(%f)", alloc(), s.bytes)
            elseif s.cl == "J" then
                asmGetRTInfo(alloc(), info(s.bytes))
            else
                error("Unknown wide constant type.")
            end
        end, function() -- 15
            --loads
            local l = u1()
            local r = alloc()
            emit("move %i %i", r, l + 1)
        end, function() -- 16
            --loads
            local l = u1()
            local r = alloc()
            emit("move %i %i", r, l + 1)
        end, function() -- 17
            --loads
            local l = u1()
            local r = alloc()
            emit("move %i %i", r, l + 1)
        end, function() -- 18
            --loads
            local l = u1()
            local r = alloc()
            emit("move %i %i", r, l + 1)
        end, function() -- 19
            --loads
            local l = u1()
            local r = alloc()
            emit("move %i %i", r, l + 1)
        end, function() -- 1A
            --load_0
            local r = alloc()
            emit("move %i 1", r)
        end, function() -- 1B
            --load_1
            local r = alloc()
            emit("move %i 2", r)
        end, function() -- 1C
            --load_2
            local r = alloc()
            emit("move %i 3", r)
        end, function() -- 1D
            --load_3
            local r = alloc()
            emit("move %i 4", r)
        end, function() -- 1E
            --load_0
            local r = alloc()
            emit("move %i 1", r)
        end, function() -- 1F
            --load_1
            local r = alloc()
            emit("move %i 2", r)
        end, function() -- 20
            --load_2
            local r = alloc()
            emit("move %i 3", r)
        end, function() -- 21
            --load_3
            local r = alloc()
            emit("move %i 4", r)
        end, function() -- 22
            --load_0
            local r = alloc()
            emit("move %i 1", r)
        end, function() -- 23
            --load_1
            local r = alloc()
            emit("move %i 2", r)
        end, function() -- 24
            --load_2
            local r = alloc()
            emit("move %i 3", r)
        end, function() -- 25
            --load_3
            local r = alloc()
            emit("move %i 4", r)
        end, function() -- 26
            --load_0
            local r = alloc()
            emit("move %i 1", r)
        end, function() -- 27
            --load_1
            local r = alloc()
            emit("move %i 2", r)
        end, function() -- 28
            --load_2
            local r = alloc()
            emit("move %i 3", r)
        end, function() -- 29
            --load_3
            local r = alloc()
            emit("move %i 4", r)
        end, function() -- 2A
            --load_0
            local r = alloc()
            emit("move %i 1", r)
        end, function() -- 2B
            --load_1
            local r = alloc()
            emit("move %i 2", r)
        end, function() -- 2C
            --load_2
            local r = alloc()
            emit("move %i 3", r)
        end, function() -- 2D
            --load_3
            local r = alloc()
            emit("move %i 4", r)
        end, function() -- 2E
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 2F
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 30
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 31
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 32
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 33
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 34
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 35
            --aaload
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(1)
            local ri = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("gettable %i %i %i", rarr, rarr, ri)

            free(6)
        end, function() -- 36
            --stores
            --lvars[u1()] = pop()
            local l = u1()
            local r = free()
            emit("move %i %i", l + 1, r)
        end, function() -- 37
            --stores
            local l = u1()
            local r = free()
            emit("move %i %i", l + 1, r)
        end, function() -- 38
            --stores
            local l = u1()
            local r = free()
            emit("move %i %i", l + 1, r)
        end, function() -- 39
            --stores
            local l = u1()
            local r = free()
            emit("move %i %i", l + 1, r)
        end, function() -- 3A
            --stores
            local l = u1()
            local r = free()
            emit("move %i %i", l + 1, r)
        end, function() -- 3B
            local r = free()
            emit("move 1 %i", r)
        end, function() -- 3C
            local r = free()
            emit("move 2 %i", r)
        end, function() -- 3D
            local r = free()
            emit("move 3 %i", r)
        end, function() -- 3E
            local r = free()
            emit("move 4 %i", r)
        end, function() -- 3F
            local r = free()
            emit("move 1 %i", r)
        end, function() -- 40
            local r = free()
            emit("move 2 %i", r)
        end, function() -- 41
            local r = free()
            emit("move 3 %i", r)
        end, function() -- 42
            local r = free()
            emit("move 4 %i", r)
        end, function() -- 43
            local r = free()
            emit("move 1 %i", r)
        end, function() -- 44
            local r = free()
            emit("move 2 %i", r)
        end, function() -- 45
            local r = free()
            emit("move 3 %i", r)
        end, function() -- 46
            local r = free()
            emit("move 4 %i", r)
        end, function() -- 47
            local r = free()
            emit("move 1 %i", r)
        end, function() -- 48
            local r = free()
            emit("move 2 %i", r)
        end, function() -- 49
            local r = free()
            emit("move 3 %i", r)
        end, function() -- 4A
            local r = free()
            emit("move 4 %i", r)
        end, function() -- 4B
            local r = free()
            emit("move 1 %i", r)
        end, function() -- 4C
            local r = free()
            emit("move 2 %i", r)
        end, function() -- 4D
            local r = free()
            emit("move 3 %i", r)
        end, function() -- 4E
            local r = free()
            emit("move 4 %i", r)
        end, function() -- 4F
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 50
            --aastore
            local rarr, ri, rval = free(3)
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 51
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 52
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 53
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 54
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 55
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 56
            --aastore
            local oobException = classByName("java.lang.ArrayIndexOutOfBoundsException")
            local con = findMethod(oobException, "<init>(I)V")

            local rarr = peek(2)
            local ri = peek(1)
            local rval = peek(0)
            local rlen, rexc, rcon, rpexc, rpi = alloc(5)
            emit("gettable %i %i k(4)", rlen, rarr)
            emit("lt 1 %i %i", ri, rlen)
            emit("")                                    -- Placeholder for jump.

            local p1 = asmPC
            asmNewInstance(rexc, oobException)
            asmGetRTInfo(rcon, info(con[1]))
            emit("move %i %i", rpi, ri)
            emit("move %i %i", rpexc, rexc)
            emit("call %i 3 3", rcon)
            asmRefillStackTrace(rexc)
            asmThrow(rexc)
            local p2 = asmPC
            emitInsert(p1 - 1, "jmp %i", p2 - p1)           -- Insert calculated jump.
            emit("add %i %i k(1)", ri, ri)
            emit("gettable %i %i k(5)", rarr, rarr)
            emit("settable %i %i %i", rarr, ri, rval)

            free(7)
        end, function() -- 57
            free()
        end, function() -- 58
            local pv = pop()
            if pv[1] ~= "D" and pv[1] ~= "J" then
                pop()
            end
        end, function() -- 59
            local r = peek(0)
            local rd = alloc(1)
            emit("move %i %i", rd, r)
        end, function() -- 5A
            local r2, r1 = peek(0), peek(1)
            local r3 = alloc(1)
            emit("move %i %i", r3, r2)
            emit("move %i %i", r2, r1)
            emit("move %i %i", r1, r3)
        end, function() -- 5B
            local v = pop()
            push(v)
            table.insert(stack,sp-(pv[1] == "D" or pv[1] == "J" and 2 or 3),{v[1], v[2]})
            sp = sp+1
        end, function() -- 5C
            local a = pop()
            if a[1] ~= "D" and a[1] ~= "J" then
                local b = pop()
                push(b)
                push(a)
                push({b[1], b[2]})
                push({a[1], a[2]})
            else
                push(a)
                push({a[1], a[2]})
            end
        end, function() -- 5D
            error("swap2_x1 is bullshit and you know it")
        end, function() -- 5E
            error("swap2_x2 is bullshit and you know it")
        end, function() -- 5F
            local a = pop()
            local b = pop()
            push(a)
            push(b)
        end, function() -- 60
            --add
            local r1 = peek(1)
            local r2 = peek(0)
            emit("add %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 61
            --ladd

            -- {high, low} + {high, low}
            --[[local r1 = peek(1)
            local r2 = peek(0)
            local r1h, r1l, r2h, r2l = alloc(4)

            emit("gettable %i %i k(1)", r1h, r1)        -- r1h = r1[1]
            emit("gettable %i %i k(2)", r1l, r1)        -- r1l = r1[2]
            emit("gettable %i %i k(1)", r2h, r2)        -- r2h = r2[1]
            emit("gettable %i %i k(2)", r2l, r2)        -- r2l = r2[2]

            emit("add %i %i %i", r1l, r1l, r2l)         -- r1l = r1l + r2l
            emit("lt 0 %i k(2147483648)", r1l)          -- if r1l >= 2^31 then jmp 2
            emit("jmp 2")

            emit("add %i %i %i", r1h, r1h, r2h)         -- r1h = r1h + r2h
            emit("jmp 2")

            -- overflow
            emit("add %i %i k(1)", r1h, r1h)            -- r1h = r1h + 1
            emit("sub %i %i k(2147483648)", r1l, r1l)   -- r1l = r1l - 2^31

            free(5)

            emit("settable %i k(1) %i", r1, r1h)        -- r1[1] = r1h
            emit("settable %i k(2) %i", r1, r1l)        -- r1[2] = r1l]]

            local r1 = peek(1)
            local r2 = peek(0)
            emit("add %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 62
            --add
            local r1 = peek(1)
            local r2 = peek(0)
            emit("add %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 63
            --add
            local r1 = peek(1)
            local r2 = peek(0)
            emit("add %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 64
            --sub
            local r1 = peek(1)
            local r2 = peek(0)
            emit("sub %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 65
            --sub
            local r1 = peek(1)
            local r2 = peek(0)
            emit("sub %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 66
            --sub
            local r1 = peek(1)
            local r2 = peek(0)
            emit("sub %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 67
            --sub
            local r1 = peek(1)
            local r2 = peek(0)
            emit("sub %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 68
            --mul
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mul %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 69
            --mul
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mul %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 6A
            --mul
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mul %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 6B
            --mul
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mul %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 6C
            --div
            local r1 = peek(1)
            local r2 = peek(0)
            emit("div %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 6D
            --div
            local r1 = peek(1)
            local r2 = peek(0)
            emit("div %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 6E
            --div
            local r1 = peek(1)
            local r2 = peek(0)
            emit("div %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 6F
            --div
            local r1 = peek(1)
            local r2 = peek(0)
            emit("div %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 70
            --rem
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mod %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 71
            --rem
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mod %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 72
            --rem
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mod %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 73
            --rem
            local r1 = peek(1)
            local r2 = peek(0)
            emit("mod %i %i %i", r1, r1, r2)
            free(1)
        end, function() -- 74
            --neg
            local r1 = peek(0)
            emit("mul %i %i k(-1)", r1, r1)
        end, function() -- 75
            --neg
            local r1 = peek(0)
            emit("mul %i %i k(-1)", r1, r1)
        end, function() -- 76
            --neg
            local r1 = peek(0)
            emit("mul %i %i k(-1)", r1, r1)
        end, function() -- 77
            --neg
            local r1 = peek(0)
            emit("mul %i %i k(-1)", r1, r1)
        end, function() -- 78
            --shl
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.blshift))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 79
            --shl
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.blshift))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 7A
            --shr
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.brshift))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 7B
            --shr
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.brshift))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 7C
            --shlr
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.blogic_rshift))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 7D
            --shlr
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.blogic_rshift))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 7E
            --and
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.band))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 7F
            --and
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.band))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 80
            --or
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.bor))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 81
            --or
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.bor))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 82
            --xor
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.bxor))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 83
            --xor
            local r1 = peek(1)
            local r2 = peek(0)
            local r3 = alloc()
            emit("move %i %i", r3, r1)
            asmGetRTInfo(r1, info(bit.bxor))
            emit("call %i 3 2", r1)
            emit("move %i %i", r1, r2)
            free(2)
        end, function() -- 84
            --iinc
            local idx = u1() + 1
            local c = u1ToSignedByte(u1())
            emit("add %i %i k(%i)", idx, idx, c)
        end, function() -- 85
            --i2l
            --push(asLong(bigInt.toBigInt(pop()[2])))
        end, function() -- 86
            --i2f
            --push(asFloat(pop()[2]))
        end, function() -- 87
            --i2d
            --push(asDouble(pop()[2]))
        end, function() -- 88
            --l2i
            --push(asInt(bigInt.fromBigInt(pop()[2])))
        end, function() -- 89
            --l2f
            --push(asFloat(bigInt.fromBigInt(pop()[2])))
        end, function() -- 8A
            --l2d
            --push(asDouble(bigInt.fromBigInt(pop()[2])))
        end, function() -- 8B
            --f2i
            --push(asInt(math.floor(pop()[2])))
        end, function() -- 8C
            --f2l
            --push(asLong(bigInt.toBigInt(math.floor(pop()[2]))))
        end, function() -- 8D
            --f2d
            --push(asDouble(pop()[2]))
        end, function() -- 8E
            --d2i
            --push(asInt(math.floor(pop()[2])))
        end, function() -- 8F
            --d2l
            --push(asLong(bigInt.toBigInt(math.floor(pop()[2]))))
        end, function() -- 90
            --d2f
            --push(asFloat(pop()[2]))
        end, function() -- 91
            --i2b
            --push(asByte(pop()[2]))
        end, function() -- 92
            --i2c
            --push(asChar(string.char(pop()[2])))
        end, function() -- 93
            --i2s
            --push(asShort(pop()[2]))
        end, function() -- 94
            --lcmp
            local a, b = pop()[2], pop()[2]
            if bigInt.cmp_eq(a, b) then
                push(asInt(0))
            elseif bigInt.cmp_lt(a, b) then
                push(asInt(1))
            else
                push(asInt(-1))
            end
        end, function() -- 95
            --fcmpl/g
            local a, b = pop()[2], pop()[2]
            if a == b then
                push(asInt(0))
            elseif a < b then
                push(asInt(1))
            else
                push(asInt(-1))
            end
        end, function() -- 96
            --fcmpl/g
            local a, b = pop()[2], pop()[2]
            if a == b then
                push(asInt(0))
            elseif a < b then
                push(asInt(1))
            else
                push(asInt(-1))
            end
        end, function() -- 97
            --fcmpl/g
            local a, b = pop()[2], pop()[2]
            if a == b then
                push(asInt(0))
            elseif a < b then
                push(asInt(1))
            else
                push(asInt(-1))
            end
        end, function() -- 98
            --fcmpl/g
            local a, b = pop()[2], pop()[2]
            if a == b then
                push(asInt(0))
            elseif a < b then
                push(asInt(1))
            else
                push(asInt(-1))
            end
        end, function() -- 99
            --ifeq
            local joffset = u2ToSignedShort(u2())
            emit("eq 1 %i k(0)", free())
            emit("#jmp %i %i", joffset, 1)
        end, function() -- 9A
            --ifne
            local joffset = u2ToSignedShort(u2())
            emit("eq 0 %i k(0)", free())
            emit("#jmp %i %i", joffset, 1)
        end, function() -- 9B
            --iflt
            local joffset = u2ToSignedShort(u2())
            emit("lt 1 %i k(0)", free())
            emit("#jmp %i %i", joffset, 1)
        end, function() -- 9C
            --ifge
            local joffset = u2ToSignedShort(u2())
            emit("lt 0 %i k(0)", free())
            emit("#jmp %i %i", joffset, 1)
        end, function() -- 9D
            --ifgt
            local joffset = u2ToSignedShort(u2())
            emit("le 0 %i k(0)", free())
            emit("#jmp %i %i", joffset, 1)
        end, function() -- 9E
            --ifle
            local joffset = u2ToSignedShort(u2())
            emit("le 1 %i k(0)", free())
            emit("#jmp %i %i", joffset, 1)
        end, function() -- 9F
            --if_icmpeq
            local joffset = u2ToSignedShort(u2())
            emit("eq 1 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A0
            --if_icmpne
            local joffset = u2ToSignedShort(u2())
            emit("eq 0 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A1
            --if_icmplt
            local joffset = u2ToSignedShort(u2())
            emit("lt 1 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A2
            --if_icmpge
            local joffset = u2ToSignedShort(u2())
            emit("lt 0 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A3
            --if_icmpgt
            local joffset = u2ToSignedShort(u2())
            emit("le 0 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A4
            --if_icmple
            local joffset = u2ToSignedShort(u2())
            emit("le 1 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A5
            --if_acmpeq
            local joffset = u2ToSignedShort(u2())
            emit("eq 1 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A6
            --if_acmpne
            local joffset = u2ToSignedShort(u2())
            emit("eq 0 %i %i", free(2))
            emit("#jmp %i %i", joffset, 1)
        end, function() -- A7
            --goto
            local joffset = u2ToSignedShort(u2())
            emit("#jmp %i %i", joffset, 0)
        end, function() -- A8
            --jsr
            error()
            local addr = pc() + 3
            local offset = u2ToSignedShort(u2())
            push({"address", addr})
            pc(pc() + offset - 2)
        end, function() -- A9
            --ret
            error()
            local index = u1()
            local addr = lvars[index]
            if addr[1] ~= "address" then
                error("Not an address", 0)
            end
            pc(addr[2])
        end, function() -- AA
            -- Unfortunately can't do any jump table optimization here since Lua doesn't
            -- have a dynamic jump instruction...
            local rkey = peek(0)

            -- Align to 4 bytes.
            local padding = 4 - pc() % 4
            pc(pc() + padding)

            local default = s4()
            local low = s4()
            local high = s4()
            local noffsets = high - low + 1

            for i = 1, noffsets do
                local offset = s4()     -- offset to jump to if rkey == match
                emit("eq 1 k(%i) %i", low + i - 1, rkey)
                emit("#jmp %i %i", offset, (i - 1) * 2 + 1)
            end

            emit("#jmp %i %i", default, noffsets * 2)
        end, function() -- AB
            local rkey = free()

            -- Align to 4 bytes.
            local padding = 4 - pc() % 4
            pc(pc() + padding)

            local default = s4()        -- default jump
            local npairs = s4()         -- number of cases

            for i = 1, npairs do
                local match = s4()      -- try to match this to the key
                local offset = s4()     -- offset to jump to if rkey == match
                emit("eq 1 k(%i) %i", match, rkey)
                emit("#jmp %i %i", offset, (i - 1) * 2 + 1)
            end

            emit("#jmp %i %i", default, npairs * 2)
        end, function() -- AC
            asmPopStackTrace()
            emit("return %i 2", free())
        end, function() -- AD
            asmPopStackTrace()
            emit("return %i 2", free())
        end, function() -- AE
            asmPopStackTrace()
            emit("return %i 2", free())
        end, function() -- AF
            asmPopStackTrace()
            emit("return %i 2", free())
        end, function() -- B0
            asmPopStackTrace()
            emit("return %i 2", free())
        end, function() -- B1
            asmPopStackTrace()
            emit("return 0 1")
        end, function() -- B2
            --getstatic
            local fr = cp[u2()]
            local class = resolveClass(cp[fr.class_index])
            local name = cp[cp[fr.name_and_type_index].name_index].bytes
            local fi = class.fieldIndexByName[name]
            local r = alloc()
            asmGetRTInfo(r, info(class.fields))
            emitWithComment(class.name.."."..name, "gettable %i %i k(%i)", r, r, fi)
        end, function() -- B3
            --putstatic
            local fr = cp[u2()]
            local class = resolveClass(cp[fr.class_index])
            local name = cp[cp[fr.name_and_type_index].name_index].bytes
            local fi = class.fieldIndexByName[name]
            local value = peek(0)
            local r = alloc()
            asmGetRTInfo(r, info(class.fields))
            emitWithComment(class.name.."."..name, "settable %i k(%i) %i", r, fi, value)
            free(2)
        end, function() -- B4
            --getfield
            local fr = cp[u2()]
            local name = cp[cp[fr.name_and_type_index].name_index].bytes
            local class = resolveClass(cp[fr.class_index])
            local fi = class.fieldIndexByName[name]
            local r = peek(0)
            emit("gettable %i %i k(2)", r, r)
            emitWithComment(class.name.."."..name, "gettable %i %i k(%i)", r, r, fi)
        end, function() -- B5
            --putfield
            local fr = cp[u2()]
            local name = cp[cp[fr.name_and_type_index].name_index].bytes
            local class = resolveClass(cp[fr.class_index])
            local fi = class.fieldIndexByName[name]
            local robj = peek(1)
            local rval = peek(0)
            local rfields = alloc()
            emit("gettable %i %i k(2)", rfields, robj)
            emitWithComment(class.name.."."..name, "settable %i k(%i) %i", rfields, fi, rval)
            free(3)
        end, function() -- B6
            --invokevirtual
            local mr = cp[u2()]
            local cl = resolveClass(cp[mr.class_index])
            local name = cp[cp[mr.name_and_type_index].name_index].bytes .. cp[cp[mr.name_and_type_index].descriptor_index].bytes
            local mt, mIndex = findMethod(cl, name)
            local argslen = #mt.desc

            asmSetStackTraceLineNumber(getCurrentLineNumber() or 0)

            -- Need 1 extra register for last argument.
            alloc()

            -- Move the arguments up.
            for i = 1, argslen do
                emit("move %i %i", peek(i - 1), peek(i))
            end

            -- Inject the method under the parameters.
            local rmt = peek(argslen)
            local objIndex = peek(argslen - 1)
            local methodTableEntry = alloc()

            asmGetRTInfo(methodTableEntry, info(mIndex))
            -- Get the methods table from the object
            emit("gettable %i %i k(3)", rmt, objIndex)
            emit("gettable %i %i %i", rmt, rmt, methodTableEntry)
            free(1)
            emit("gettable %i %i k(1)", rmt, rmt)
            -- Invoke the method. Result is right after the method.
            emitWithComment(cl.name.."."..name, "call %i %i 3", rmt, argslen + 1)

            -- Free down to ret, exception
            -- Same as freeing all arguments except the argument representing the object
            free(argslen - 1)
            local ret, exception = rmt, rmt + 1
            asmCheckThrow(exception)

            if mt.desc[#mt.desc].type ~= "V" then
                -- free exception
                free()
            else
                -- free nil, exception
                free(2)
            end
        end, function() -- B7
            --invokespecial
            local mr = cp[u2()]
            local cl = resolveClass(cp[mr.class_index])
            local name = cp[cp[mr.name_and_type_index].name_index].bytes .. cp[cp[mr.name_and_type_index].descriptor_index].bytes
            local mt = findMethod(cl, name)
            local argslen = #mt.desc

            asmSetStackTraceLineNumber(getCurrentLineNumber() or 0)

            -- Need 1 extra register for last argument. 
            alloc()

            -- Move the arguments up.
            for i = 1, argslen do
                emit("move %i %i", peek(i - 1), peek(i))
            end

            -- Inject the method under the parameters.
            local rmt = peek(argslen)
            asmGetRTInfo(rmt, info(mt))

            -- Invoke the method. Result is right after the method.
            emit("gettable %i %i k(1)", rmt, rmt)
            emitWithComment(cl.name.."."..name, "call %i %i 3", rmt, argslen + 1)

            -- Free down to ret, exception
            -- Same as freeing all arguments except the argument representing the object
            free(argslen - 1)
            local ret, exception = rmt, rmt + 1
            asmCheckThrow(exception)

            if mt.desc[#mt.desc].type ~= "V" then
                -- free exception
                free()
            else
                -- free nil, exception
                free(2)
            end
        end, function() -- B8
            --invokestatic
            local mr = cp[u2()]
            local cl = resolveClass(cp[mr.class_index])
            local name = cp[cp[mr.name_and_type_index].name_index].bytes .. cp[cp[mr.name_and_type_index].descriptor_index].bytes
            local mt = findMethod(cl, name)
            local argslen = #mt.desc - 1

            asmSetStackTraceLineNumber(getCurrentLineNumber() or 0)

            -- Need 1 extra register for last argument. 
            alloc()

            -- Move the arguments up.
            for i = 1, argslen do
                emit("move %i %i", peek(i - 1), peek(i))
            end

            -- Inject the method under the parameters.
            local rmt = peek(argslen)
            asmGetRTInfo(rmt, info(mt))

            -- Invoke the method. Result is right after the method.
            emit("gettable %i %i k(1)", rmt, rmt)
            emitWithComment(cl.name.."."..name, "call %i %i 3", rmt, argslen + 1)

            -- Free down to ret, exception
            -- More complicated than other invokes
            -- Might actually need to allocate a slot if the method had no arguments
            if argslen == 0 then
                alloc()
            else
                free(argslen - 1)
            end
            local ret, exception = rmt, rmt + 1
            asmCheckThrow(exception)

            if mt.desc[#mt.desc].type ~= "V" then
                -- free exception
                free()
            else
                -- free nil, exception
                free(2)
            end
        end, function() -- B9
            --invokeinterface
            local mr = cp[u2()]
            u2() -- two dead bytes in invokeinterface
            local cl = resolveClass(cp[mr.class_index])
            local name = cp[cp[mr.name_and_type_index].name_index].bytes .. cp[cp[mr.name_and_type_index].descriptor_index].bytes
            local mt = findMethod(cl, name)
            local argslen = #mt.desc

            asmSetStackTraceLineNumber(getCurrentLineNumber() or 0)

            -- Need 1 extra register for last argument.
            alloc()

            -- Move the arguments up.
            for i = 1, argslen do
                emit("move %i %i", peek(i - 1), peek(i))
            end

            -- Inject the method under the parameters.
            local rmt = peek(argslen)
            local obj = peek(argslen - 1)

            -- find the method
            local find, rcl, rname = alloc(3)
            asmGetRTInfo(find, info(findMethod))
            emit("gettable %i %i k(1)", rcl, obj)
            asmGetRTInfo(rname, info(name))
            emit("call %i 3 2", find)
            emit("move %i %i", rmt, find)
            free(3)

            -- Invoke the method. Result is right after the method.
            emit("gettable %i %i k(1)", rmt, rmt)
            emitWithComment(cl.name.."."..name, "call %i %i 3", rmt, argslen + 1)

            -- Free down to ret, exception
            -- Same as freeing all arguments except the argument representing the object
            free(argslen - 1)
            local ret, exception = rmt, rmt + 1
            asmCheckThrow(exception)

            if mt.desc[#mt.desc].type ~= "V" then
                -- free exception
                free()
            else
                -- free nil, exception
                free(2)
            end
        end, function() -- BA
            error("BA not implemented.") -- TODO
        end, function() -- BB
            --new
            local cr = cp[u2()]
            local c = resolveClass(cr)
            local robj = alloc()
            asmNewInstance(robj, c)
        end, function() -- BC
            --newarray
            local cn = "["..ARRAY_TYPES[u1()]
            local class = getArrayClass(cn)

            local rlength = peek(0)
            local robj = alloc()
            asmNewPrimitiveArray(robj, rlength, class)
            --put array in expected register
            emit("move %i %i", rlength, robj)
            free()
        end, function() -- BD
            --anewarray
            local cn = "[L"..cp[cp[u2()].name_index].bytes:gsub("/",".")..";"
            local class = getArrayClass(cn)

            local rlength = peek(0)
            local robj = alloc()
            asmNewArray(robj, rlength, class)
            --put array in expected register
            emit("move %i %i", rlength, robj)
            free()
        end, function() -- BE
            --arraylength
            local r = peek(0)
            emit("gettable %i %i k(4)", r, r)
        end, function() -- BF
            local rexception = peek(0)
            asmRefillStackTrace(rexception)
            asmThrow(rexception)
        end, function() -- C0
            local c = resolveClass(cp[u2()])
            local r = peek(0)
            local rjInstanceof, robj, rclass = alloc(3)
            emit("move %i %i", robj, r)
            asmGetRTInfo(rclass, info(c))
            asmGetRTInfo(rjInstanceof, info(jInstanceof))
            emit("call %i 3 2", rjInstanceof)
            local rassert, rsuccess, rmsg = rjInstanceof, robj, rclass
            emit("move %i %i", rsuccess, rjInstanceof)
            asmGetRTInfo(rassert, info(assert))
            asmGetRTInfo(rmsg, info("Failed to cast to "..c.name))
            emit("call %i 3 1", rassert)
            free(3)
        end, function() -- C1
            local c = resolveClass(cp[u2()])
            asmInstanceOf(c)
        end, function() -- C2
            error("C2 not implemented.") -- TODO
        end, function() -- C3
            error("C3 not implemented.") -- TODO
        end, function() -- C4
            error("C4 not implemented.") -- TODO
        end, function() -- C5
            error("C5 not implemented.") -- TODO
        end, function() -- C6
            local joffset = u2ToSignedShort(u2())
            local rvalue = free()
            emit("eq 1 %i nil", rvalue)
            emit("#jmp %i %i", joffset, 1)
        end, function() -- C7
            local joffset = u2ToSignedShort(u2())
            local rvalue = free()
            emit("eq 0 %i nil", rvalue)
            emit("#jmp %i %i", joffset, 1)
        end, function() -- C8
            error("C8 not implemented.") -- TODO
        end, function() -- C9
            error("C9 not implemented.") -- TODO
        end, function() -- CA
            error("CA not implemented.") -- TODO
        end, function() -- CB
            error("CB not implemented.") -- TODO
        end, function() -- CC
            error("CC not implemented.") -- TODO
        end, function() -- CD
            error("CD not implemented.") -- TODO
        end, function() -- CE
            error("CE not implemented.") -- TODO
        end, function() -- CF
            error("CF not implemented.") -- TODO
        end, function() -- D0
            error("D0 not implemented.") -- TODO
        end, function() -- D1
            error("D1 not implemented.") -- TODO
        end, function() -- D2
            error("D2 not implemented.") -- TODO
        end, function() -- D3
            error("D3 not implemented.") -- TODO
        end, function() -- D4
            error("D4 not implemented.") -- TODO
        end, function() -- D5
            error("D5 not implemented.") -- TODO
        end, function() -- D6
            error("D6 not implemented.") -- TODO
        end, function() -- D7
            error("D7 not implemented.") -- TODO
        end, function() -- D8
            error("D8 not implemented.") -- TODO
        end, function() -- D9
            error("D9 not implemented.") -- TODO
        end, function() -- DA
            error("DA not implemented.") -- TODO
        end, function() -- DB
            error("DB not implemented.") -- TODO
        end, function() -- DC
            error("DC not implemented.") -- TODO
        end, function() -- DD
            error("DD not implemented.") -- TODO
        end, function() -- DE
            error("DE not implemented.") -- TODO
        end, function() -- DF
            error("DF not implemented.") -- TODO
        end, function() -- E0
            error("E0 not implemented.") -- TODO
        end, function() -- E1
            error("E1 not implemented.") -- TODO
        end, function() -- E2
            error("E2 not implemented.") -- TODO
        end, function() -- E3
            error("E3 not implemented.") -- TODO
        end, function() -- E4
            error("E4 not implemented.") -- TODO
        end, function() -- E5
            error("E5 not implemented.") -- TODO
        end, function() -- E6
            error("E6 not implemented.") -- TODO
        end, function() -- E7
            error("E7 not implemented.") -- TODO
        end, function() -- E8
            error("E8 not implemented.") -- TODO
        end, function() -- E9
            error("E9 not implemented.") -- TODO
        end, function() -- EA
            error("EA not implemented.") -- TODO
        end, function() -- EB
            error("EB not implemented.") -- TODO
        end, function() -- EC
            error("EC not implemented.") -- TODO
        end, function() -- ED
            error("ED not implemented.") -- TODO
        end, function() -- EE
            error("EE not implemented.") -- TODO
        end, function() -- EF
            error("EF not implemented.") -- TODO
        end, function() -- F0
            error("F0 not implemented.") -- TODO
        end, function() -- F1
            error("F1 not implemented.") -- TODO
        end, function() -- F2
            error("F2 not implemented.") -- TODO
        end, function() -- F3
            error("F3 not implemented.") -- TODO
        end, function() -- F4
            error("F4 not implemented.") -- TODO
        end, function() -- F5
            error("F5 not implemented.") -- TODO
        end, function() -- F6
            error("F6 not implemented.") -- TODO
        end, function() -- F7
            error("F7 not implemented.") -- TODO
        end, function() -- F8
            error("F8 not implemented.") -- TODO
        end, function() -- F9
            error("F9 not implemented.") -- TODO
        end, function() -- FA
            error("FA not implemented.") -- TODO
        end, function() -- FB
            error("FB not implemented.") -- TODO
        end, function() -- FC
            error("FC not implemented.") -- TODO
        end, function() -- FD
            error("FD not implemented.") -- TODO
        end, function() -- FE
            error("FE not implemented.") -- TODO
        end, function() -- FF
            error("FF not implemented.") -- TODO
        end
    }

    local offset = -1
    local entryIndex = 0
    inst = u1()
    asmPushStackTrace()
    while inst do
        -- check the stack map
        if stackMapAttribute and stackMapAttribute.entries[entryIndex] then
            local entry = stackMapAttribute.entries[entryIndex]
            local newOffset = offset + entry.offset_delta + 1
            if pc() == newOffset then
                entryIndex = entryIndex + 1
                offset = newOffset

                freeTo(entry.stack_items)
            end
        end

        -- compile the instruction
        pcMapLJ[asmPC] = pc()
        pcMapJL[pc()] = asmPC
        oplookup[inst]()
        inst = u1()
    end

    for i = 1, #asm do
        local inst = asm[i]
        if inst:sub(1, 4) == "#jmp" then
            local _, _, sjoffset, sjmpLOffset = inst:find("^#jmp ([+-]?%d+) ([+-]?%d+)")

            -- Java instruction to jump to
            local jpc
            if sjoffset and sjmpLOffset then
                local joffset, jmpLOffset = tonumber(sjoffset), tonumber(sjmpLOffset)
                jpc = pcMapLJ[i - jmpLOffset] + joffset
            else
                local _, _, sjpc = inst:find("^#jmp %((%d+)%)")
                jpc = tonumber(sjpc)
            end

            -- Lua instruction to jump to
            local lpc = pcMapJL[jpc]
            -- Lua offset
            local loffset = lpc - i - 1
            asm[i] = "jmp " .. loffset .. "\n"
        end
    end

    debugH.write(class.name .. "." .. method.name .. "\n")
    debugH.write("Length: " .. (asmPC - 1) .. "\n")
    debugH.write("Locals: " .. codeAttr.max_locals .. "\n")
    for i = 1, #asm do
        if pcMapLJ[i] then
            debugH.write(string.format("[%i] %X:\n", pcMapLJ[i], code[pcMapLJ[i]]))
        end
        debugH.write(string.format("\t[%i] %s", i, asm[i]:gsub("\n$", function()
            if comments[i] then
                return comments[i] .. "\n"
            else
                return "\n"
            end
        end)))
    end
    debugH.write("\n")
    debugH.flush()
    --print(table.concat(asm))

    --print("Loading and verifying bytecode for " .. name)
    local p = LAT.Lua51.Parser:new()
    local file = p:Parse(".options 0 " .. (codeAttr.max_locals + 1) .. table.concat(asm), class.name .. "." .. method.name.."/bytecode")
    --file:StripDebugInfo()
    local bc = file:Compile()
    local f = loadstring(bc)
    --print(table.concat(asm))

    return f, rti
    --popStackTrace()
end

function createCodeFunction(class, method, codeAttr, cp)
    local f
    local rti
    return function(...)
        if not f then
            f, rti = compile(class, method, codeAttr, cp)
        end
        return f(rti, ...)
    end
end