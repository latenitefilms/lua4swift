import Foundation
import CLua

internal let RegistryIndex = Int(-LUAI_MAXSTACK - 1000)
private let GlobalsTable = Int(LUA_RIDX_GLOBALS)

public struct Lua {
    public typealias ErrorHandler = (String) -> Void

    public enum Kind: CustomStringConvertible {
        case string
        case number
        case boolean
        case function
        case table
        case userdata
        case lightUserdata
        case thread
        case `nil`
        case none

        internal func luaType() -> Int32 {
            switch self {
            case .string: return LUA_TSTRING
            case .number: return LUA_TNUMBER
            case .boolean: return LUA_TBOOLEAN
            case .function: return LUA_TFUNCTION
            case .table: return LUA_TTABLE
            case .userdata: return LUA_TUSERDATA
            case .lightUserdata: return LUA_TLIGHTUSERDATA
            case .thread: return LUA_TTHREAD
            case .nil: return LUA_TNIL
            case .none: return LUA_TNONE
            }
        }

        public var description: String {
            switch self {
            case .string: return "String"
            case .number: return "Lua.Number"
            case .boolean: return "Bool"
            case .function: return "Lua.Function"
            case .table: return "Lua.Table"
            case .userdata: return "Lua.Userdata"
            case .lightUserdata: return "Lua.LightUserdata"
            case .thread: return "Lua.Thread"
            case .nil: return "Lua.Nil"
            case .none: return "Lua.None"
            }
        }
    }

    open class VirtualMachine {

        public let state = luaL_newstate()

        open var errorHandler: ErrorHandler? = { print("error: \($0)") }

        public init(openLibs: Bool = true) {
            if openLibs { luaL_openlibs(state) }
        }

        deinit {
            lua_close(state)
        }

        public func preloadModules(_ modules: UnsafeMutablePointer<luaL_Reg>) {
            lua_getglobal(state, "package")
            lua_getfield(state, -1, "preload");

            var module = modules.pointee

            while let name = module.name, let function = module.func {
                lua_pushcclosure(state, function, 0)
                lua_setfield(state, -2, name)

                module = modules.advanced(by: 1).pointee
            }

            lua_settop(state, -(2)-1)
        }

        internal func kind(_ pos: Int) -> Kind {
            switch lua_type(state, Int32(pos)) {
            case LUA_TSTRING: return .string
            case LUA_TNUMBER: return .number
            case LUA_TBOOLEAN: return .boolean
            case LUA_TFUNCTION: return .function
            case LUA_TTABLE: return .table
            case LUA_TUSERDATA: return .userdata
            case LUA_TLIGHTUSERDATA: return .lightUserdata
            case LUA_TTHREAD: return .thread
            case LUA_TNIL: return .nil
            default: return .none
            }
        }

        // pops the value off the stack completely and returns it
        internal func popValue(_ pos: Int) -> LuaValueRepresentable? {
            moveToStackTop(pos)
            var v: LuaValueRepresentable?
            switch kind(-1) {
            case .string:
                var len: Int = 0
                let str = lua_tolstring(state, -1, &len)
                v = String(cString: str!)
            case .number:
                v = Number(self)
            case .boolean:
                v = lua_toboolean(state, -1) == 1 ? true : false
            case .function:
                v = Function(self)
            case .table:
                v = Table(self)
            case .userdata:
                v = Userdata(self)
            case .lightUserdata:
                v = LightUserdata(self)
            case .thread:
                v = Thread(self)
            case .nil:
                v = Nil()
            default: break
            }
            pop()
            return v
        }

        open var globals: Table {
            rawGet(tablePosition: RegistryIndex, index: GlobalsTable)
            return popValue(-1) as! Table
        }

        open var registry: Table {
            pushFromStack(RegistryIndex)
            return popValue(-1) as! Table
        }

        open func createFunction(_ body: URL) throws -> Function {
            if luaL_loadfilex(state, body.path, nil) == LUA_OK {
                return popValue(-1) as! Function
            } else {
                throw Lua.Error(popError())
            }
        }

        open func createFunction(_ body: String) throws -> Function {
            if luaL_loadstring(state, body.cString(using: .utf8)) == LUA_OK {
                return popValue(-1) as! Function
            } else {
                throw Lua.Error(popError())
            }
        }

        open func createTable(_ sequenceCapacity: Int = 0, keyCapacity: Int = 0) -> Table {
            lua_createtable(state, Int32(sequenceCapacity), Int32(keyCapacity))
            return popValue(-1) as! Table
        }

        internal func popError() -> String {
            let err = popValue(-1) as! String
            if let fn = errorHandler { fn(err) }
            return err
        }

        open func createUserdataMaybe<T: LuaCustomTypeInstance>(_ o: T?) -> Userdata? {
            if let u = o {
                return createUserdata(u)
            }
            return nil
        }

        open func createUserdata<T: LuaCustomTypeInstance>(_ o: T) -> Userdata {
            let userdata = lua_newuserdatauv(state, MemoryLayout<T>.size, 1) // this both pushes ptr onto stack and returns it

            let ptr = userdata!.bindMemory(to: T.self, capacity: 1)
            ptr.initialize(to: o) // creates a new legit reference to o

            luaL_setmetatable(state, T.luaTypeName().cString(using: .utf8)) // this requires ptr to be on the stack
            return popValue(-1) as! Userdata // this pops ptr off stack
        }

        open func eval(_ url: URL, args: [LuaValueRepresentable] = []) throws -> [LuaValueRepresentable] {
            let fn = try createFunction(url)
            return try eval(function: fn, args: args)
        }

        open func eval(_ str: String, args: [LuaValueRepresentable] = []) throws -> [LuaValueRepresentable] {
            let fn = try createFunction(str)
            return try eval(function: fn, args: args)
        }

        public func eval(function f: Function, args: [LuaValueRepresentable]) throws -> [LuaValueRepresentable] {
            try f.call(args)
        }

        public func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> [LuaValueRepresentable]) -> Function {
            let f: @convention(block) (OpaquePointer) -> Int32 = { [weak self] _ in
                guard let vm = self else { return 0 }

                // build args list
                var args = [LuaValueRepresentable]()
                for _ in 0 ..< vm.stackSize() {
                    guard let arg = vm.popValue(1) else { break }
                    args.append(arg)
                }

                // call fn
                do {
                    let values = try fn(args)
                    values.forEach { $0.push(vm) }
                    return Int32(values.count)
                } catch {
                    let e = (error as? LocalizedError)?.errorDescription ?? "Swift Error \(error)"
                    e.push(vm)
                    lua_error(vm.state)
                    return 0 // uhh, we don't actually get here
                }
            }
            let block: AnyObject = unsafeBitCast(f, to: AnyObject.self)
            let imp = imp_implementationWithBlock(block)

            let fp = unsafeBitCast(imp, to: lua_CFunction.self)
            lua_pushcclosure(state, fp, 0)
            return popValue(-1) as! Function
        }

        public func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> LuaValueRepresentable) -> Function {
            self.createFunction {
                try [fn($0)]
            }
        }

        public func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> Void) -> Function {
            self.createFunction {
                try fn($0)
                return []
            }
        }

        fileprivate func argError(_ expectedType: String, at argPosition: Int) {
            luaL_typeerror(state, Int32(argPosition), expectedType.cString(using: .utf8))
        }

        open func createCustomType<T>(_ setup: (CustomType<T>) -> Void) -> CustomType<T> {
            lua_createtable(state, 0, 0)
            let lib = CustomType<T>(self)
            pop()

            setup(lib)

            registry[T.luaTypeName()] = lib
            lib.becomeMetatableFor(lib)
            lib["__index"] = lib
            lib["__name"] = T.luaTypeName()

            let gc = lib.gc
            lib["__gc"] = createFunction { args in
                let ud = try Userdata.unwrap(self, args[0])
                (ud.userdataPointer() as UnsafeMutablePointer<T>).deinitialize(count: 1)
                let o: T = ud.toCustomType()
                gc?(o)
                return []
            }

            if let eq = lib.eq {
                lib["__eq"] = createFunction { args in
                    let a: T = try Userdata.unwrap(self, args[0]).toCustomType()
                    let b: T = try Userdata.unwrap(self, args[1]).toCustomType()
                    return [eq(a, b)]
                }
            }
            return lib
        }

        // stack

        internal func moveToStackTop(_ position: Int) {
            var position = position
            if position == -1 || position == stackSize() { return }
            position = absolutePosition(position)
            pushFromStack(position)
            remove(position)
        }

        internal func ref(_ position: Int) -> Int { return Int(luaL_ref(state, Int32(position))) }
        internal func unref(_ table: Int, _ position: Int) { luaL_unref(state, Int32(table), Int32(position)) }
        internal func absolutePosition(_ position: Int) -> Int { return Int(lua_absindex(state, Int32(position))) }
        internal func rawGet(tablePosition: Int, index: Int) { lua_rawgeti(state, Int32(tablePosition), lua_Integer(index)) }

        internal func pushFromStack(_ position: Int) {
            lua_pushvalue(state, Int32(position))
        }

        internal func pop(_ n: Int = 1) {
            lua_settop(state, -Int32(n)-1)
        }

        internal func rotate(_ position: Int, n: Int) {
            lua_rotate(state, Int32(position), Int32(n))
        }

        internal func remove(_ position: Int) {
            rotate(position, n: -1)
            pop(1)
        }

        internal func stackSize() -> Int {
            return Int(lua_gettop(state))
        }

    }
}
