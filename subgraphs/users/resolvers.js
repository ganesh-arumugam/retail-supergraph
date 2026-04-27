import { users } from "./data.js";
import { GraphQLError } from "graphql";
import { v4 as uuidv4 } from "uuid";

const getUserById = (/** @type {string} */ id) =>
  users.find((it) => it.id === id);

export const resolvers = {
  Query: {
    users: () => users,
    user(_, __, context) {
      //console.log("Payload ", _, __, context);
      const userId = context.headers["x-user-id"];
      console.log("USer arg ", userId);
      const user = getUserById(userId);

      if (!user) {
        throw new GraphQLError(
          "Could not locate user by id. Please specify a valid `x-user-id` header like `user:1`"
        );
      }

      return user;
    },
  },
  User: {
    __resolveReference(ref) {
      return getUserById(ref.id);
    },
    previousSessions: () => [uuidv4(), uuidv4()],
    loyaltyPoints: (user) => (user.loyaltyPoints ?? 0),
  },
};
