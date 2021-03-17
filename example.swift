


protocol Top { 
    associatedtype LocalStorage
}

class X: Top { 
    typealias LocalStorage = String 
}
